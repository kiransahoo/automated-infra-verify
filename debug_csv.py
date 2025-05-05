#!/usr/bin/env python3
"""
CSV Debug Script - Shows exactly what values are being read from each field
"""
import sys
import csv

def debug_csv(filename):
    print(f"Opening file: {filename}")
    try:
        with open(filename, 'r', newline='', encoding='utf-8') as f:
            # Print raw file content first
            print("\n--- RAW FILE CONTENT ---")
            raw_content = f.read()
            print(repr(raw_content))  # This will show hidden characters
            
            # Reset file pointer
            f.seek(0)
            
            # Read as CSV
            print("\n--- CSV PARSING RESULTS ---")
            reader = csv.reader(f)
            headers = next(reader)
            print(f"Headers: {[repr(h) for h in headers]}")
            
            # Process rows
            for row_num, row in enumerate(reader, 1):
                print(f"\nRow {row_num}:")
                if len(row) < len(headers):
                    print(f"  WARNING: Row has fewer fields ({len(row)}) than headers ({len(headers)})")
                
                for i, value in enumerate(row):
                    header = headers[i] if i < len(headers) else f"Column{i+1}"
                    print(f"  {header}: '{value}' (repr: {repr(value)})")
                
                # Check specifically for the 'enabled' field
                if 'enabled' in headers:
                    enabled_idx = headers.index('enabled')
                    if enabled_idx < len(row):
                        enabled_value = row[enabled_idx]
                        print(f"  'enabled' value would match 'yes'?: {enabled_value == 'yes'}")
                        print(f"  'enabled' value would match 'YES'?: {enabled_value == 'YES'}")
                        print(f"  'enabled' value would match 'Yes'?: {enabled_value == 'Yes'}")
                        print(f"  'enabled' value would match 'y'?: {enabled_value == 'y'}")
                        print(f"  'enabled' value would match 'true'?: {enabled_value == 'true'}")
                        print(f"  'enabled' value would match '1'?: {enabled_value == '1'}")
                
    except Exception as e:
        print(f"Error processing CSV file: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <csv_file>")
        sys.exit(1)
    
    debug_csv(sys.argv[1])