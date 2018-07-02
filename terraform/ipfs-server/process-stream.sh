#!/bin/bash

HLS_TIME=15
HLS_LIST_SIZE=10

# Load settings
. ~/settings

function startFFmpeg() {
  while true; do
    mv /var/log/ffmpeg /var/log/ffmpeg.1
    ffmpeg -nostats -re -i "${RTMP_STREAM}" -f mpegts -vcodec copy -hls_time ${HLS_TIME} -hls_list_size ${HLS_LIST_SIZE} -f hls $what.m3u8 > /var/log/ffmpeg 2>&1
    sleep 1
  done
}

# Create directory for HLS content
rm -rf ~/live
mkdir ~/live
cd ~/live

what="$(date +%Y%m%d%H%M)-LIVE"

# Start ffmpeg in background
startFFmpeg &

while true; do
  nextfile=$(ls -tr $what*.ts 2>/dev/null | tail -n 1)

  if ! [ -z "$nextfile" ]; then
    # Check if the next file on the list is still being written to by ffmpeg
    if ! [ -z "$(lsof $nextfile | grep ffmpeg)" ]; then
      # Wait for file to finish writing
      # If not finished in 45 seconds something is wrong, timeout
      inotifywait -e close_write $nextfile -t 45
    fi

    # Grab the timecode from the m3u8 file so we can add it to the log
    timecode=`grep -B1 $nextfile $what.m3u8 | head -n1 | awk -F : '{print $2}' | tr -d ,`
    attempts=10
    until [[ "$timecode" || $attempts -eq 0 ]]; do
      sleep 0.2
      timecode=`grep -B1 $nextfile $what.m3u8 | head -n1 | awk -F : '{print $2}' | tr -d ,`
      attempts=$((attempts-1))
    done

    # What we will call this file later
    time=`date "+%F-%H-%M-%S"`

    # Add the file to IPFS
    ipfs add $nextfile > ~/tmp.txt
    
    # Update the log with the future name (hash already there)
    echo $(cat ~/tmp.txt) $time.ts $timecode >> ~/process-stream.log    
    
    # Remove nextfile and tmp.txt
    rm -f $nextfile ~/tmp.txt

    # Write the m3u8 file with the new IPFS hashes from the log
    totalLines="$(wc -l $what.m3u8 | awk '{print $1}')"
    
    sequence=0
    if (( "$totalLines" > ${HLS_LIST_SIZE} )); then
        sequence=`expr $totalLines - ${HLS_LIST_SIZE}`
    fi
    echo "#EXTM3U" > current.m3u8
    echo "#EXT-X-VERSION:3" >> current.m3u8
    echo "#EXT-X-TARGETDURATION:15" >> current.m3u8
    echo "#EXT-X-MEDIA-SEQUENCE:$sequence" >> current.m3u8

    tail -n ${HLS_LIST_SIZE} ~/process-stream.log | awk '{print "#EXTINF:"$5",\n'${IPFS_GATEWAY}'/ipfs/"$2}' >> current.m3u8

    # IPNS publish
    m3u8hash=$(ipfs add current.m3u8 | awk '{print $2}')
    ipfs name publish --timeout=5s $m3u8hash &
  else
    sleep 5
  fi
done
