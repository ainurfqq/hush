#!/usr/bin/env bash
# Builds a synthetic two-speaker meeting from a TSV (speaker<TAB>text) with macOS `say`.
# Output: <name>.wav (16 kHz mono) + <name>.ref.tsv (start, end, speaker) ground truth.
# Usage: make_meeting.sh meeting1.tsv "Damayanti" "Daniel" [pitchB]
set -euo pipefail
tsv="$1"; voiceA="$2"; voiceB="$3"; pitchB="${4:-}"
name="${tsv%.tsv}"; work="$(mktemp -d)"; gap=0.6; rate=165
: > "$work/list.txt"; : > "$name.ref.tsv"; t=0; i=0
ffmpeg -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t "$gap" -y "$work/gap.wav"
while IFS=$'\t' read -r spk text; do
  [ -z "$spk" ] && continue
  i=$((i+1)); voice="$voiceA"; [ "$spk" = "B" ] && voice="$voiceB"
  say -v "$voice" -r "$rate" -o "$work/$i.aiff" "$text"
  filt="aresample=16000"
  if [ "$spk" = "B" ] && [ -n "$pitchB" ]; then filt="asetrate=22050*$pitchB,aresample=16000,atempo=1/$pitchB"; fi
  ffmpeg -loglevel error -i "$work/$i.aiff" -af "$filt" -ac 1 -ar 16000 -y "$work/$i.wav"
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$work/$i.wav")
  printf '%.3f\t%.3f\t%s\n' "$t" "$(echo "$t + $d" | bc -l)" "$spk" >> "$name.ref.tsv"
  t=$(echo "$t + $d + $gap" | bc -l)
  printf "file '%s'\nfile '%s'\n" "$work/$i.wav" "$work/gap.wav" >> "$work/list.txt"
done < "$tsv"
ffmpeg -loglevel error -f concat -safe 0 -i "$work/list.txt" -ac 1 -ar 16000 -c:a pcm_s16le -y "$name.wav"
rm -rf "$work"
echo "$name.wav $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$name.wav")s, $i turns"
