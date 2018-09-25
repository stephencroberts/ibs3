#!/usr/bin/env bash

command -v aws
if [ "$?" -ne "0"]; then
  echo "AWS CLI is not installed!"
  exit 1
fi

command -v jq
if [ "$?" -ne "0"]; then
  echo "jq is not installed!"
  exit 1
fi

UPLOAD_PART_SIZE=20 # MB

display_usage() {
  printf "Usage: incbak [--daily | --weekly | --monthly | --yearly | --base] \
[directory]\n\n"
  printf "Restore: Backup files must be restored in order: base -> yearly -> \
monthly -> weekly -> daily. You must specify the snar file accompanying each \
backup as well as the level.\n\ntar --listed-incremental=[snar] --level=[level]\
 -zxvpf [file]\n"
}

LEVEL=0
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

printf "\e[34m######################\n# INCREMENTAL BACKUP #\n#################\
#####\n\n"
printf "\e[32mPerforming a $SNAR_DST backup for $1...\n\n\e[0m"

: ${S3_BUCKET?S3 bucket is required! Set S3_BUCKET.}
TAR=${TAR:-tar}
DATE=$(date +%Y-%m-%d)

if [ -z "$1" ]; then
  echo "backup: missing source directory"
  display_usage
  exit 1
fi

create_archive() {
  local snar_src=$1
  local level=$2
  local snar_dst=$3
  local dir=$4

  if [ ! -z "$snar_src" ]; then
    printf "\e[32mUsing $snar_src to create a $snar_dst incremental backup...\n\n\e[0m"
    cp "${snar_src}_${dir}.snar" "$dir.snar"
  fi

  $TAR --listed-incremental="$dir.snar" \
       --level=$level \
       --gzip \
       --create \
       --preserve-permissions \
       --verbose \
       --file="${snar_dst}_${dir}_${DATE}.tar.gz" \
       "$dir"

  cp "$dir.snar" "${snar_dst}_${dir}_${DATE}.snar"
  mv "$dir.snar" "${snar_dst}_${dir}.snar"
}

create_archive "$SNAR_SRC" $LEVEL "$SNAR_DST" "$1"

if [ "$SNAR_DST" = "base" ]; then
  create_archive base 1 yearly "$1"
  create_archive yearly 2 monthly "$1"
  create_archive monthly 3 weekly "$1"
  create_archive weekly 4 daily "$1"
fi

files=($(ls *${DATE}*))
for file in "${files[@]}"; do
  size=$(du -k "$file" | cut -f1)
  if [ "$size" -gt "102400" ]; then
    printf "\e[32mUploading $file to S3 using multipart upload...\n\n\e[0m"

    # Create multipart upload
    response=$(aws s3api create-multipart-upload --bucket $S3_BUCKET --key "$file" --metadata md5=$(openssl md5 -binary "$file" | base64))
    echo $response | jq '.'
    if [ "$?" -ne "0" ]; then
      echo "Failed to create multipart upload: $file"
      exit 1
    fi
    upload_id=$(echo $response | jq -r '.UploadId')

    # Split file into parts
    split -b ${UPLOAD_PART_SIZE}m "$file" "$file.part."

    # Upload parts
    parts=($(ls "$file.part"*))
    request_parts=""
    part_num=1
    for part in "${parts[@]}"; do
      printf "\e[32mUploading $part...\n\e[0m"
      aws s3api upload-part \
        --bucket $S3_BUCKET \
        --key "$file" \
        --part-number $part_num \
        --body "$part" \
        --upload-id $upload_id \
        --content-md5 $(openssl md5 -binary "$part" | base64)

      part_num=$((part_num+1))
    done

    aws s3api list-parts \
      --bucket $S3_BUCKET \
      --key "$file" \
      --upload-id $upload_id | jq -r '{ Parts: (.Parts | map(del(.LastModified, .Size))) }' > "$file.parts.json"

    printf "\e[32mCompleting multipart upload...\n\e[0m"
    aws s3api complete-multipart-upload \
      --multipart-upload "file://$file.parts.json" \
      --bucket $S3_BUCKET \
      --key "$file" \
      --upload-id $upload_id

    if [ "$?" -ne "0" ]; then
      echo "Failed to upload: $file"
      exit 1
    fi

    rm "$file.part"*
  else
    printf "\e[32mUploading $file to S3...\n\n\e[0m"
    aws s3api put-object \
      --bucket $S3_BUCKET \
      --key "$file" \
      --body "$file"
    if [ "$?" -ne "0" ]; then
      echo "Failed to upload: $file"
      exit 1
    fi
  fi
done

rm *${1}_${DATE}*

printf "\e[32mBackup complete!\n\e[0m"

