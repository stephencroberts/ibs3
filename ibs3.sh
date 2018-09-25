#!/usr/bin/env bash
#
# ibs3 - incremental backups to S3
#
# Configuration:
#   S3_BUCKET (required)
#   S3_UPLOAD_PART_SIZE (optional) - defaults to 100MB
#
# Usage:
#   ibs3 [--daily | --weekly | --monthly | --yearly | --base ] [directory]
#
# Crons:
#   0 0 2-6,8-13,15-20,22-27,29-31 * * S3_BUCKET=<bucket> /usr/local/sbin/ibs3
#     --daily <directory>
#   0 0 7,14,21,28 * * S3_BUCKET=<bucket> /usr/local/sbin/ibs3 --weekly
#     <directory>
#   0 0 1 2-12 * S3_BUCKET=<bucket> /usr/local/sbin/ibs3 --monthly <directory>
#   0 0 1 1 * S3_BUCKET=<bucket> /usr/local/sbin/ibs3 --yearly <directory>

# Part size for multi-part uploads (in MB)
UPLOAD_PART_SIZE=${S3_UPLOAD_PART_SIZE:-100}

#################
# Formats output
#################
print_heading() {
  printf "\e[34m$1\n\e[0m"
}
print_status() {
  printf "\e[32m$1\n\e[0m"
}
print_error() {
  printf "\e[31m$1\n\e[0m"
}

######################################################
# Checks if a given command is available
#
# Arguments:
#   command
# Returns:
#   None
######################################################
check_installed() {
  command -v $1 > /dev/null
  if [ "$?" -ne "0" ]; then
    print_error "$1 is not installed!"
    exit 1
  fi
}

########################
# Displays script usage
########################
display_usage() {
  printf "Usage: ibs3 [--daily | --weekly | --monthly | --yearly | --base] \
[directory]\n\n"
  printf "Restore: Backup files must be restored in order: base -> yearly -> \
monthly -> weekly -> daily. You must specify the snar file accompanying each \
backup as well as the level.\n\ntar --listed-incremental=[snar] --level=[level]\
 -zxvpf [file]\n"
}

#############################################################################
# Creates an incremental backup archive
#
# Arguments:
#   snar file for the basis of the incremental backup (base, yearly, monthly,
#     weekly, daily)
#   backup level
#   output snar file (base, yearly, monthly, weekly, daily)
#   directory to backup
#   output file name
# Returns:
#   None
#############################################################################
create_archive() {
  local snar_src=$1
  local level=$2
  local snar_dst=$3
  local dir=$4
  local dst=$5

  if [ ! -z "$snar_src" ]; then
    print_status "Using $snar_src to create a $snar_dst incremental backup...\n"
    cp "${snar_src}_${dir}.snar" "$dir.snar"
  fi

  $TAR --listed-incremental="$dir.snar" \
       --level=$level \
       --gzip \
       --create \
       --preserve-permissions \
       --verbose \
       --file="${dst}.tar.gz" \
       "$dir"

  cp "$dir.snar" "${dst}.snar"
  mv "$dir.snar" "${snar_dst}_${dir}.snar"
}

######################
# Upload a file to S3
#
# Globals:
#   S3_BUCKET
# Arguments:
#   file
# Returns:
#   None
######################
upload() {
  print_status "Uploading $file to S3...\n"
  local tries=0
  while : ; do
    aws s3api put-object \
      --bucket $S3_BUCKET \
      --key "$file" \
      --body "$file"
    [ "$?" -eq "0" ] && break
    print_error "Failed to upload: $file"
    [ "$tries" -ge "2" ] && exit 1
    tries=$((tries+1))
    print_status "Retrying..."
  done
}

#######################################
# Upload a file to S3 using multi-part
#
# Globals:
#   S3_BUCKET
#   UPLOAD_PART_SIZE
# Arguments:
#   file
# Returns:
#   None
#######################################
upload_multipart() {
  print_status "Uploading $file to S3 using multipart upload...\n"

  # Create multipart upload
  local response
  local tries=0
  while : ; do
    response=$(aws s3api create-multipart-upload \
      --bucket $S3_BUCKET \
      --key "$file" \
      --metadata md5=$(openssl md5 -binary "$file" | base64)
    )
    [ "$?" -eq "0" ] && break
    print_error "Failed to create multipart upload: $file"
    [ "$tries" -ge "2" ] && exit 1
    tries=$((tries+1))
    print_status "Retrying..."
  done

  echo $response | jq '.'
  local upload_id=$(echo $response | jq -r '.UploadId')


  # Split file into parts
  split -b ${UPLOAD_PART_SIZE}m "$file" "$file.part."

  # Upload parts
  local parts=($(ls "$file.part"*))
  local part_num=1
  for part in "${parts[@]}"; do
    print_status "Uploading $part..."
    local tries=0
    while : ; do
      aws s3api upload-part \
        --bucket $S3_BUCKET \
        --key "$file" \
        --part-number $part_num \
        --body "$part" \
        --upload-id $upload_id \
        --content-md5 $(openssl md5 -binary "$part" | base64)
      [ "$?" -eq "0" ] && break
      print_error "Failed to upload part: $part"
      [ "$tries" -ge "2" ] && exit 1
      tries=$((tries+1))
      print_status "Retrying..."
    done

    part_num=$((part_num+1))
  done

  local response
  local tries=0
  while : ; do
    response=$(aws s3api list-parts \
      --bucket $S3_BUCKET \
      --key "$file" \
      --upload-id $upload_id
    )
    [ "$?" -eq "0" ] && break
    print_error "Failed to list multipart upload parts: $file"
    [ "$tries" -ge "2" ] && exit 1
    tries=$((tries+1))
    print_status "Retrying..."
  done
  echo $response | jq -r '{ Parts: (.Parts | map(del(.LastModified, .Size))) }'\
      > "$file.parts.json"

  print_status "Completing multipart upload..."
  local tries=0
  while : ; do
    aws s3api complete-multipart-upload \
      --multipart-upload "file://$file.parts.json" \
      --bucket $S3_BUCKET \
      --key "$file" \
      --upload-id $upload_id
    [ "$?" -eq "0" ] && break
    print_error "Failed to complete multipart upload: $file"
    [ "$tries" -ge "2" ] && exit 1
    tries=$((tries+1))
    print_status "Retrying..."
  done

  rm "$file.part"*
}

# Parse command options
LEVEL=0
SNAR_DST=base
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
    -d|--daily)
    LEVEL=4
    SNAR_SRC=weekly
    SNAR_DST=daily
    shift # past argument
    ;;
    -w|--weekly)
    LEVEL=3
    SNAR_SRC=monthly
    SNAR_DST=weekly
    shift # past argument
    ;;
    -m|--monthly)
    LEVEL=2
    SNAR_SRC=yearly
    SNAR_DST=monthly
    shift # past argument
    ;;
    -y|--yearly)
    LEVEL=1
    SNAR_SRC=base
    SNAR_DST=yearly
    ;;
    -b|--base)
    LEVEL=0
    SNAR_DST=base
    shift # past argument
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
  esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters


print_heading "#############################\n# INCREMENTAL BACKUPS TO S3 #\n##\
###########################\n"

TAR=${TAR:-tar}
DATE=$(date +%Y-%m-%d)

check_installed aws
check_installed jq
check_installed openssl

# GNU tar is required
$TAR --version | grep GNU > /dev/null
if [ "$?" -ne "0" ]; then
  print_error "tar with incremental backup support is required. Install GNU tar."
  exit 1
fi

: ${S3_BUCKET?S3 bucket is required! Set S3_BUCKET.}

if [ -z "$1" ]; then
  print_error "$0: missing source directory"
  display_usage
  exit 1
fi

if [ ! -e "$1" ]; then
  print_error "$0: source directory not found: $1"
  exit 1
fi


print_status "Performing a $SNAR_DST backup for $1...\n"

create_archive "$SNAR_SRC" $LEVEL "$SNAR_DST" "$1" "${SNAR_DST}_${1}_${DATE}"

if [ "$SNAR_DST" = "base" ]; then
  create_archive base 1 yearly "$1" "yearly_${1}_${DATE}"
  create_archive yearly 2 monthly "$1" "monthly_${1}_${DATE}"
  create_archive monthly 3 weekly "$1" "weekly_${1}_${DATE}"
  create_archive weekly 4 daily "$1" "daily_${1}_${DATE}"
fi

if [ "$SNAR_DST" = "yearly" ]; then
  create_archive yearly 2 monthly "$1" "monthly_${1}_${DATE}"
  create_archive monthly 3 weekly "$1" "weekly_${1}_${DATE}"
  create_archive weekly 4 daily "$1" "daily_${1}_${DATE}"
fi

if [ "$SNAR_DST" = "monthly" ]; then
  create_archive monthly 3 weekly "$1" "weekly_${1}_${DATE}"
  create_archive weekly 4 daily "$1" "daily_${1}_${DATE}"
fi

if [ "$SNAR_DST" = "weekly" ]; then
  create_archive weekly 4 daily "$1" "daily_${1}_${DATE}"
fi

files=($(ls *${DATE}*))
for file in "${files[@]}"; do
  size=$(du -k "$file" | cut -f1)
  if [ "$size" -gt "102400" ]; then
    upload_multipart "$file"
  else
    upload "$file"
  fi
done

rm *${1}_${DATE}*

print_status "Backup complete!"

