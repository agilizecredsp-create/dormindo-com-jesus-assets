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

# ---------- 0. Baixar fonte mais "amigável" (estilo infantil, arredondada) ----------
# Usada na thumbnail e na vinheta de CTA. Se o download falhar por qualquer motivo
# (rede instável no runner), cai de volta pra DejaVu Bold (já vem instalada no ubuntu-latest).
FONT="fonte_titulo.ttf"
curl -sL -o "$FONT" "https://raw.githubusercontent.com/google/fonts/main/ofl/baloo2/Baloo2%5Bwght%5D.ttf" || true
if [ ! -s "$FONT" ]; then
  echo "Aviso: download da fonte Baloo 2 falhou, usando DejaVu Sans Bold como fallback"
  FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
fi

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
# IMPORTANTE: os Shorts são cortados AQUI, a partir do video_final.mp4 original
# (sem a vinheta de CTA), pra manter os timestamps dos cortes fiéis ao conteúdo real.
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
# ---------- 5. Gerar thumbnail customizada (nome do canal + duração) ----------
# A base da thumbnail agora é um FRAME REAL tirado de dentro do vídeo já renderizado
# (em vez de uma imagem estática solta), porque assim ela sai sempre com o mesmo
# enquadramento/zoom que o vídeo final -- mais consistente entre execuções.
echo "== Gerando thumbnail customizada =="
THUMB_TIME=$(echo "$DURACAO_ALVO_SEG * 0.15" | bc | cut -d. -f1)
ffmpeg -y -ss "$THUMB_TIME" -i video_final.mp4 -frames:v 1 thumb_base.jpg -loglevel error

if [ "$DURACAO_ALVO_SEG" -ge 3600 ]; then
  THUMB_HORAS=$(( DURACAO_ALVO_SEG / 3600 ))
  THUMB_MIN_REST=$(( (DURACAO_ALVO_SEG % 3600) / 60 ))
  if [ "$THUMB_MIN_REST" -gt 0 ]; then
    DURACAO_TEXTO="${THUMB_HORAS}H${THUMB_MIN_REST}MIN"
  else
    DURACAO_TEXTO="${THUMB_HORAS}H"
  fi
else
  THUMB_MINUTOS=$(( DURACAO_ALVO_SEG / 60 ))
  DURACAO_TEXTO="${THUMB_MINUTOS} MINUTOS"
fi
# Texto com contorno + sombra em vez de caixa sólida -- fica legível sobre qualquer
# fundo sem parecer uma faixa colada por cima da imagem.
ffmpeg -y -i thumb_base.jpg \
  -vf "scale=1280:720,\
drawtext=fontfile=${FONT}:text='DORMINDO COM JESUS':fontsize=76:fontcolor=white:borderw=10:bordercolor=black@0.85:shadowx=3:shadowy=3:shadowcolor=black@0.6:x=(w-text_w)/2:y=44,\
drawtext=fontfile=${FONT}:text='${DURACAO_TEXTO}':fontsize=58:fontcolor=white:borderw=8:bordercolor=black@0.85:shadowx=3:shadowy=3:shadowcolor=black@0.6:x=w-text_w-36:y=h-text_h-32" \
  -frames:v 1 thumbnail.jpg -loglevel error
echo "== Thumbnail gerada =="
ls -la thumbnail.jpg
# ---------- 6. Gerar vinheta de CTA (convite pra se inscrever) e anexar ao final do vídeo ----------
# A vinheta entra só no vídeo principal, depois que os Shorts já foram cortados (passo 4),
# pra não interferir no conteúdo/timing dos Shorts. Mesmo estilo de texto da thumbnail
# (contorno + sombra, sem caixa) pra manter a identidade visual consistente.
echo "== Gerando vinheta de inscrição (CTA) =="
CTA_DUR=5
CTA_IMG="img_01.png"
ffmpeg -y -loop 1 -i "$CTA_IMG" -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 -t "$CTA_DUR" \
  -vf "scale=1920:1080,fps=25,\
drawtext=fontfile=${FONT}:text='Inscreva-se no canal!':fontsize=92:fontcolor=white:borderw=12:bordercolor=black@0.85:shadowx=4:shadowy=4:shadowcolor=black@0.6:x=(w-text_w)/2:y=(h-text_h)/2-60,\
drawtext=fontfile=${FONT}:text='Dormindo com Jesus':fontsize=62:fontcolor=white:borderw=9:bordercolor=black@0.85:shadowx=3:shadowy=3:shadowcolor=black@0.6:x=(w-text_w)/2:y=(h-text_h)/2+70,\
fade=t=in:st=0:d=0.5,fade=t=out:st=$(echo "$CTA_DUR - 0.5" | bc):d=0.5" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -shortest vinheta.mp4 -loglevel error
echo "== Anexando vinheta ao final do vídeo principal =="
echo "file '$(pwd)/video_final.mp4'" > concat_cta_list.txt
echo "file '$(pwd)/vinheta.mp4'" >> concat_cta_list.txt
ffmpeg -y -f concat -safe 0 -i concat_cta_list.txt -c copy video_final_com_cta.mp4 -loglevel error
mv video_final_com_cta.mp4 video_final.mp4
echo "== Vídeo final com CTA pronto =="
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 video_final.mp4
ls -la video_final.mp4 thumbnail.jpg short_1.mp4 short_2.mp4
