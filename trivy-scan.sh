#!/bin/bash

# Define variables
image="image-name:tag"
output_file="${image##*/}"            # Remove registry prefix
output_file="${output_file/:/-}"      # Replace colon with dash
report_dir="$(pwd)/reports"
template_file="$(pwd)/html.tpl"
final_destination="$(pwd)/reports/my_report"
# Create directories if they don't exist
mkdir -p "$report_dir" "$(dirname "$final_destination")"

# Create directories if they don't exist
mkdir -p "$report_dir" "$(dirname "$final_destination")"

# Run Trivy scan
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$(pwd)/caches:/root/.cache/" \
  -v "$(pwd)/reports:/output" \
  aquasec/trivy image \
  --format table \
  -o "/output/$output_file.html" \
  --scanners vuln \
  "$image"
# Check if scan succeeded
if [ -f "$report_dir/$output_file.html" ]; then
  # Copy report to final destination
  cp "$report_dir/$output_file.html" "$final_destination"
  echo "Report generated and copied to: $final_destination"
else
  echo "Error: Scan failed - report not generated"
  exit 1
fi
