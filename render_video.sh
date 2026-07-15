#!/bin/bash
set -e
# ============================================================
# Script de renderização de vídeo longo (loop de imagens + música)
# Recebe parâmetros via variáveis de ambiente (setadas pelo workflow do GitHub Actions,
# que por sua vez recebe do N8N via repository_dispatch)
#
# Variáveis esperadas:
#   AUDIO_URLS_JSON   -> ex: '["https://.../audio1.mp3","https://.../audio2.mp3"]'
#   IMAGE_URLS_JSON   -> ex: '["https://.../imagem-01.png","https://.../imagem-02.png"]'
#   DURACAO_ALVO_SEG  -> ex: 5400 (90 minutos)
# ============================================================
WORKDIR="render_work"
rm -rf "$WORKDIR" && mkdir -p "$WORKDIR"
cd "$WORKDIR"
XFADE_DUR=0.5
echo "== Baixando áudios =="
echo "$AUDIO_URLS_JSON" | jq -r '.[]' | nl -w2 -nrz | while read -r idx url; do
  curl -sL "$url" -o "audio_${idx}.mp3"
done
echo "== Baixando imagens =="
echo "$IMAGE_URLS_JSON" | jq -r '.[]' | nl -w2 -nrz | while read -r idx url; do
  curl -sL "$url" -o "img_${idx}.png"
done
NUM_IMAGENS=$(echo "$IMAGE_URLS_JSON" | jq 'length')
echo "Total de imagens: $NUM_IMAGENS"
# ---------- 1. Montar o áudio em loop até bater a duração alvo ----------
echo "== Montando áudio em loop =="
ls audio_*.mp3 | sort > audio_list_base.txt
NUM_FAIXAS=$(wc -l < audio_list_base.txt)
# soma a duração real das faixas (via ffprobe, não assume valor fixo)
DURACAO_FAIXAS=0
while read -r f; do
  D=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f")
  DURACAO_FAIXAS=$(echo "$DURACAO_FAIXAS + $D" | bc -l)
done < audio_list_base.txt
REPETICOES=$(echo "($DURACAO_ALVO_SEG / $DURACAO_FAIXAS) + 1" | bc)
echo "Duração das faixas somadas: ${DURACAO_FAIXAS}s | Repetições necessárias: $REPETICOES"
> audio_concat_list.txt
for i in $(seq 1 "$REPETICOES"); do
  while read -r f; do
    echo "file '$(pwd)/$f'" >> audio_concat_list.txt
  done < audio_list_base.txt
done
ffmpeg -y -f concat -safe 0 -i audio_concat_list.txt -t "$DURACAO_ALVO_SEG" -c:a aac audio_final.m4a -loglevel error
# ---------- 2. Montar o vídeo (imagens em loop com zoom + crossfade) ----------
echo "== Gerando segmentos de imagem =="
PERDA_TOTAL=$(echo "($NUM_IMAGENS - 1) * $XFADE_DUR" | bc -l)
DURACAO_COM_COMPENSACAO=$(echo "$DURACAO_ALVO_SEG + $PERDA_TOTAL" | bc -l)
DURACAO_POR_IMAGEM=$(echo "$DURACAO_COM_COMPENSACAO / $NUM_IMAGENS" | bc -l)
echo "Duração por imagem (com compensação de transição): ${DURACAO_POR_IMAGEM}s"
INPUTS=""
for ((i=1; i<=NUM_IMAGENS; i++)); do
  IDX=$(printf "%02d" "$i")
  IMG_FILE="img_${IDX}.png"
  ffmpeg -y -loop 1 -i "$IMG_FILE" -t "$DURACAO_POR_IMAGEM" \
    -vf "scale=1920:1080,zoompan=z='min(zoom+0.0008,1.3)':d=$(echo "$DURACAO_POR_IMAGEM * 25" | bc | cut -d. -f1):s=1920x1080:fps=25" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p "seg_${IDX}.mp4" -loglevel error
  INPUTS="$INPUTS -i seg_${IDX}.mp4"
done
echo "== Montando crossfade entre segmentos =="
FILTER=""
OFFSET=$(echo "$DURACAO_POR_IMAGEM - $XFADE_DUR" | bc -l)
PREV="[0:v]"
for ((n=1; n<NUM_IMAGENS; n++)); do
  NEXT_LABEL="[v$n]"
  if [ $n -eq $((NUM_IMAGENS-1)) ]; then
    NEXT_LABEL="[vfinal]"
  fi
  FILTER="${FILTER}${PREV}[${n}:v]xfade=transition=fade:duration=${XFADE_DUR}:offset=${OFFSET}${NEXT_LABEL}; "
  PREV="[v$n]"
  OFFSET=$(echo "$OFFSET + $DURACAO_POR_IMAGEM - $XFADE_DUR" | bc -l)
done
FILTER=${FILTER%; }
eval ffmpeg -y $INPUTS -filter_complex \"$FILTER\" -map \"[vfinal]\" -c:v libx264 -preset veryfast -pix_fmt yuv420p video_sem_audio.mp4 -loglevel error
# ---------- 3. Juntar áudio + vídeo final ----------
echo "== Juntando áudio e vídeo =="
ffmpeg -y -i video_sem_audio.mp4 -i audio_final.m4a -c:v copy -c:a aac -shortest video_final.mp4 -loglevel error
echo "== Concluído =="
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 video_final.mp4
ls -la video_final.mp4
# ---------- 4. Gerar Shorts (2 cortes verticais 9:16) ----------
echo "== Gerando Shorts =="
SHORT_DUR=50
INICIO_SHORT_1=0
INICIO_SHORT_2=$(echo "$DURACAO_ALVO_SEG * 0.4" | bc | cut -d. -f1)
# garante que o segundo corte nao ultrapasse o fim do video
MAX_INICIO=$(echo "$DURACAO_ALVO_SEG - $SHORT_DUR" | bc)
if (( $(echo "$INICIO_SHORT_2 > $MAX_INICIO" | bc -l) )); then
  INICIO_SHORT_2=$MAX_INICIO
fi
gerar_short() {
  local INICIO=$1
  local OUT=$2
  ffmpeg -y -ss "$INICIO" -i video_final.mp4 -t "$SHORT_DUR" \
    -filter_complex "[0:v]split=2[bg][fg]; \
      [bg]scale=1080:1920,gblur=sigma=20,crop=1080:1920[bgblur]; \
      [fg]scale=1080:-2[fgscaled]; \
      [bgblur][fgscaled]overlay=(W-w)/2:(H-h)/2" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac "$OUT" -loglevel error
}
gerar_short "$INICIO_SHORT_1" "short_1.mp4"
gerar_short "$INICIO_SHORT_2" "short_2.mp4"
echo "== Shorts gerados =="
ls -la short_1.mp4 short_2.mp4
