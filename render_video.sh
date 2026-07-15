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
