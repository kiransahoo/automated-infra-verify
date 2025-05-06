#!/usr/bin/env python3
"""
CSV handler for connectivity tests - requires only built-in Python modules
"""
import sys
import csv
import os
import json

def process_csv(input_file, output_file, file_type="endpoints"):
    """Process a CSV file for endpoints or tests"""
    try:
        if not os.path.exists(input_file):
            print(f"Error: Input file {input_file} not found")
            return False
            
        # Read the CSV file
        with open(input_file, 'r', newline='', encoding='utf-8') as f:
            reader = csv.reader(f)
            headers = next(reader)  # Get the header row
            rows = list(reader)     # Get all data rows
        
        # Process headers to match expected format
        normalized_headers = [h.lower().strip() for h in headers]
        
        if file_type == "endpoints":
            # Map input columns to expected columns
            column_map = {}
            for i, header in enumerate(normalized_headers):
                if any(term in header for term in ['type', 'endpoint']):
                    column_map['endpoint_type'] = i
                elif any(term in header for term in ['host', 'server', 'address']):
                    column_map['hostname'] = i
                elif 'port' in header:
                    column_map['port'] = i
                elif any(term in header for term in ['desc', 'name', 'detail']):
                    column_map['description'] = i
                elif any(term in header for term in ['group', 'rg']):
                    column_map['resource_group'] = i
                elif any(term in header for term in ['sub', 'subscription']):
                    column_map['subscription_id'] = i
            
            # Check for required columns
            if 'hostname' not in column_map or 'port' not in column_map:
                print("Error: Input CSV must have columns for hostname and port")
                return False
                
            # Process rows
            output_rows = []
            
            for row in rows:
                if not row:  # Skip empty rows
                    continue
                    
                # Create a new row with mapped columns
                output_row = {}
                output_row['endpoint_type'] = row[column_map.get('endpoint_type', 0)] if 'endpoint_type' in column_map else 'custom'
                output_row['hostname'] = row[column_map['hostname']]
                output_row['port'] = row[column_map['port']]
                output_row['description'] = row[column_map.get('description', 0)] if 'description' in column_map else output_row['hostname']
                output_row['resource_group'] = row[column_map.get('resource_group', 0)] if 'resource_group' in column_map else 'unknown'
                output_row['subscription_id'] = row[column_map.get('subscription_id', 0)] if 'subscription_id' in column_map else 'unknown'
                
                # Only add rows with valid hostname and port
                if output_row['hostname'] and output_row['port']:
                    output_rows.append(output_row)
            
            # Write output CSV
            with open(output_file, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=['endpoint_type', 'hostname', 'port', 'description', 'resource_group', 'subscription_id'])
                writer.writeheader()
                writer.writerows(output_rows)
                
            print(f"Processed {len(output_rows)} endpoints")
            return True
            
        elif file_type == "tests":
            # Map input columns to expected columns for tests
            column_map = {}
            for i, header in enumerate(normalized_headers):
                if ('test' in header and ('id' in header or 'name' in header)):
                    column_map['test_id'] = i
                elif 'source' in header and 'type' in header:
                    column_map['source_type'] = i
                elif header == 'source' or ('source' in header and 'name' in header):
                    column_map['source'] = i
                elif 'dest' in header and 'type' in header:
                    column_map['destination_type'] = i
                elif header == 'destination' or ('dest' in header and not 'type' in header):
                    column_map['destination'] = i
                elif any(term in header for term in ['enable', 'run', 'active']):
                    column_map['enabled'] = i
            
            # Check for required columns
            if 'source' not in column_map or 'destination' not in column_map:
                print("Error: Input CSV must have columns for source and destination")
                return False
                
            # Process rows
            output_rows = []
            
            for i, row in enumerate(rows):
                if not row:  # Skip empty rows
                    continue
                    
                # Create a new row with mapped columns
                output_row = {}
                output_row['test_id'] = row[column_map.get('test_id', 0)] if 'test_id' in column_map else f"test_{i+1}"
                output_row['source_type'] = row[column_map.get('source_type', 0)] if 'source_type' in column_map else 'auto'
                output_row['source'] = row[column_map['source']]
                output_row['destination_type'] = row[column_map.get('destination_type', 0)] if 'destination_type' in column_map else 'auto'
                output_row['destination'] = row[column_map['destination']]
                
                # Handle enabled column
                if 'enabled' in column_map:
                    enabled_val = row[column_map['enabled']].lower()
                    output_row['enabled'] = 'yes' if enabled_val in ['yes', 'y', 'true', '1', 'enabled', 'active'] else 'no'
                else:
                    output_row['enabled'] = 'yes'
                
                # Only add rows with valid source and destination
                if output_row['source'] and output_row['destination']:
                    output_rows.append(output_row)
            
            # Write output CSV
            with open(output_file, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=['test_id', 'source_type', 'source', 'destination_type', 'destination', 'enabled'])
                writer.writeheader()
                writer.writerows(output_rows)
                
            print(f"Processed {len(output_rows)} test cases")
            return True
            
        else:
            print(f"Error: Unknown file type: {file_type}")
            return False
            
    except Exception as e:
        print(f"Error processing CSV: {e}")
        return False

def convert_excel_to_csv(excel_file, csv_file):
    """Try to convert Excel to CSV using a simplified approach"""
    print("Note: pandas and openpyxl are not installed.")
    print("Please convert your Excel file to CSV manually or install the required packages:")
    print("pip3 install --user pandas openpyxl")
    print("\nFor now, assuming the file is already in CSV format.")
    
    # If file is already CSV, just return the path
    if excel_file.lower().endswith('.csv'):
        if os.path.exists(excel_file):
            # Just copy the file
            with open(excel_file, 'r') as src, open(csv_file, 'w') as dst:
                dst.write(src.read())
            return True
        else:
            print(f"Error: CSV file {excel_file} not found")
            return False
    else:
        print(f"Please convert {excel_file} to CSV format manually and re-run the script.")
        return False

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python csv_handler.py <input_file> <output_file> <type> [sheet_name]")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    file_type = sys.argv[3]
    
    # Handle Excel files
    if input_file.lower().endswith(('.xlsx', '.xls')):
        temp_csv = f"{os.path.splitext(input_file)[0]}.csv"
        if not convert_excel_to_csv(input_file, temp_csv):
            sys.exit(1)
        input_file = temp_csv
    
    # Process the CSV file
    if not process_csv(input_file, output_file, file_type):
        sys.exit(1)
