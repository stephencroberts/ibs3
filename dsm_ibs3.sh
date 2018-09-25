#!/usr/bin/env bash
#
# Runs an ibs3 backup on the correct interval if this script is run daily
#
# Author: Stephen Roberts <stephenroberts@gmail.com>
#
# WARNING: This script is designed for use with Synology DSM Scheduled Tasks.
#
# Usage:
#   Copy this script to /usr/local/sbin/dsm_ibs3 with execute permissions
#   Create a daily scheduled task as follows:
#     S3_BUCKET=[bucket] /usr/local/sbin/dsm_ibs3 [/absolute/path/to/directory]

set -e

MONTH=$(date '+%m')
DAY=$(date '+%d')
if [ "$MONTH" -eq "1" ] && [ "$DAY" -eq "1" ]; then
  INTERVAL=yearly
elif [ "$DAY" -eq "1" ]; then
  INTERVAL=monthly
elif [ "$DAY" -eq "7" ] || [ "$DAY" -eq "14" ] || [ "$DAY" -eq "21" ] || [ "$DAY" -eq "28" ]; then
  INTERVAL=weekly
else
  INTERVAL=daily
fi

cd "$1/.." && /usr/local/sbin/ibs3 "--$INTERVAL" "$(basename "$1")"
