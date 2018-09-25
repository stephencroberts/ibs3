ibs3
====

Incremental backups to S3

## Getting Started

- Copy `ibs3.sh` to `/usr/local/sbin/ibs3` and make it executable
- `cd` to the parent directory of the directory to backup
- Run `ibs3` with `--base` to create the first backup (see [#usage](#usage))
- Create cron jobs to automate backups (see [#cron](#cron))

## Usage

```shell
ibs3 [--daily | --weekly | --monthly | --yearly | --base ] [directory]
```

## Configuration

envar | required | description
--- | --- | ---
S3_BUCKET | yes | S3 bucket to backup to
S3_UPLOAD_PART_SIZE | no | File size (MB) for each part of a multipart upload

## Cron

```
0 0 2-6,8-13,15-20,22-27,29-31 * * S3_BUCKET=[bucket] /usr/local/sbin/ibs3 --daily [directory]
0 0 7,14,21,28 * * S3_BUCKET=[bucket] /usr/local/sbin/ibs3 --weekly [directory]
0 0 1 2-12 * S3_BUCKET=[bucket] /usr/local/sbin/ibs3 --monthly [directory]
0 0 1 1 * S3_BUCKET=[bucket] /usr/local/sbin/ibs3 --yearly [directory]
```

## Overview

`ibs3` performs incremental backups of a given directory with support for daily,
weekly, monthly, yearly, and base snapshots. Longer intervals also include
backups for the shorter intervals. For instance, the weekly backup will also
create a daily backup, and a monthly backup will include weekly and daily
backups. This is because the backups must be done in order of decreasing
interval since each backup uses the next largest interval as a base for the
snapshot. The cron jobs are scheduled so that only one backup is run each day.

## Implementation

The incremental backup is performed using `tar`. The AWS CLI is used to upload
backups to S3, and multi-part uploads are used for large files.

## Restoring

Restoring backups requires files to be restored in order: base, yearly, monthly,
weekly, and daily. To obtain the most recent copy, use the latest of each of
those.

You must specify the snar file accompanying each backup as well as the level:

```shell
tar --listed-incremental=[snar] --level=[level] -zxvpf [file]
```

