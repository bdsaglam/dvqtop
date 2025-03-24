# dvqtop

A script to poll the DVC queue and send notifications via [ntfy](https://ntfy.sh) when all jobs are done.


## Installation

```sh
cp ./dvqtop.sh ~/.local/bin/
chmod +x ~/.local/bin/dvqtop.sh
```

## Usage

```sh
dvqtop.sh  [-n <poll_interval>] [-t <ntfy_topic>]
```