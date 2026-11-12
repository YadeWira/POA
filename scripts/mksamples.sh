#!/bin/bash
# Regenerates the test samples in tests/ogg from synthetic signals
# (ffmpeg's lavfi sources), so the repository carries no third-party audio.
# ffmpeg with libvorbis, libopus, libspeex and libtheora.
set -euo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)/tests/ogg
mkdir -p "$D"
F="ffmpeg -hide_banner -loglevel error -y"
mus="sine=f=220:d=4,volume=0.3[a];sine=f=331:d=4,volume=0.2[b];sine=f=440:d=4,volume=0.1[c];anoisesrc=d=4:c=pink:a=0.05[n];[a][b][c][n]amix=inputs=4"
st="$mus,asplit[l][r];[r]adelay=7[r2];[l][r2]amerge=inputs=2"
# Vorbis: qualities, rates, channels
for q in -1 0 2 4 6 8 10; do
  $F -filter_complex "$st" -ar 44100 -c:a libvorbis -q:a $q "$D/vorbis_q${q}_44k_st.ogg"
done
for r in 8000 11025 16000 22050 32000 48000; do
  $F -filter_complex "$mus" -ar $r -c:a libvorbis -q:a 3 "$D/vorbis_q3_${r}_mono.ogg"
done
$F -f lavfi -i "sine=f=1000:d=0.3" -c:a libvorbis -q:a 4 "$D/vorbis_click.ogg"
$F -f lavfi -i "anullsrc=r=44100:cl=stereo" -t 2 -c:a libvorbis "$D/vorbis_silence.ogg"
$F -f lavfi -i "anoisesrc=d=2:c=white:a=0.5" -c:a libvorbis -q:a 5 "$D/vorbis_noise.ogg"
$F -f lavfi -i "aevalsrc=sin(2*PI*(200+800*t)*t)|sin(2*PI*(300+600*t)*t):d=3:s=44100" -c:a libvorbis -q:a 5 "$D/vorbis_sweep_st.ogg"
$F -f lavfi -i "sine=f=440:d=2" -ac 6 -c:a libvorbis "$D/vorbis_51.ogg"
# chained: two links
$F -f lavfi -i "sine=f=300:d=1" -c:a libvorbis "$D/link1.tmp.ogg"
$F -f lavfi -i "sine=f=500:d=1" -ac 2 -c:a libvorbis "$D/link2.tmp.ogg"
cat "$D/link1.tmp.ogg" "$D/link2.tmp.ogg" > "$D/vorbis_chained.ogg"
rm -f "$D"/*.tmp.ogg
# other codecs
$F -filter_complex "$st" -c:a libopus -b:a 64k "$D/opus_64k_st.opus"
$F -filter_complex "$mus" -c:a libopus -b:a 16k "$D/opus_16k_mono.opus"
$F -filter_complex "$mus" -ar 16000 -c:a libspeex "$D/speex_16k.spx"
$F -filter_complex "$mus" -t 1 -ar 22050 -sample_fmt s16 -c:a flac "$D/flac_mono.oga"
$F -f lavfi -i "testsrc=d=2:s=160x120:r=15" -f lavfi -i "sine=f=440:d=2" \
   -c:v libtheora -q:v 5 -c:a libvorbis -shortest "$D/theora_vorbis.ogv"
ls -la "$D" | tail -n +2
du -sh "$D"
