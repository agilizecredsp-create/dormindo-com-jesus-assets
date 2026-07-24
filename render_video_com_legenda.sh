#!/bin/bash
set -e
# ============================================================
# Script de renderização de vídeo (loop de imagens + música) COM LEGENDA KARAOKÊ
# Variante do render_video.sh original -- NAO substitui o script de producao.
# Usar apenas no workflow novo "render-legenda.yml" ate ser validado.
#
# Variáveis esperadas (iguais ao script original):
#   AUDIO_URLS_JSON   -> ex: '["https://.../audio1.mp3","https://.../audio2.mp3"]'
#   IMAGE_URLS_JSON   -> ex: '["https://.../imagem-01.png","https://.../imagem-02.png"]'
#   DURACAO_ALVO_SEG  -> ex: 5400 (90 minutos)
# ============================================================
WORKDIR="render_work"
rm -rf "$WORKDIR" && mkdir -p "$WORKDIR"
cd "$WORKDIR"
XFADE_DUR=0.5

# ---------- 0. Baixar fonte + instalar dependências Python ----------
FONT="fonte_titulo.ttf"
curl -sL -o "$FONT" "https://raw.githubusercontent.com/google/fonts/main/ofl/baloo2/Baloo2%5Bwght%5D.ttf" || true
if [ ! -s "$FONT" ]; then
  echo "Aviso: download da fonte Baloo 2 falhou, usando DejaVu Sans Bold como fallback"
  FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
fi
echo "== Instalando Pillow (thumbnail) e faster-whisper (legenda karaokê) =="
pip install pillow faster-whisper --break-system-packages --quiet 2>/dev/null || pip install pillow faster-whisper --quiet

echo "== Baixando template fixo da thumbnail =="
THUMB_TEMPLATE_URL="https://raw.githubusercontent.com/agilizecredsp-create/dormindo-com-jesus-assets/main/ChatGPT%20Image%2019%20de%20jul.%20de%202026,%2011_09_25.png"
curl -sL -o thumb_template.png "$THUMB_TEMPLATE_URL"

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

# ---------- 1. Transcrever CADA FAIXA ÚNICA com timestamps por palavra ----------
# So transcreve as faixas base (antes do loop), que sao bem mais curtas que os
# 90 minutos finais -- economiza muito tempo de execucao no runner.
# Faixas instrumentais simplesmente nao geram palavras (fica sem legenda ali).
echo "== Transcrevendo faixas com faster-whisper (timestamps por palavra) =="
cat > transcrever.py << 'PYEOF'
import sys, json, glob
from faster_whisper import WhisperModel

model = WhisperModel("base", device="cpu", compute_type="int8")

resultado = {}
for audio_file in sorted(glob.glob("audio_*.mp3")):
    print(f"Transcrevendo {audio_file}...")
    segments, info = model.transcribe(
        audio_file, word_timestamps=True, language="pt",
        vad_filter=True  # ignora trechos sem fala, reduz alucinacao em trechos instrumentais
    )
    palavras = []
    for seg in segments:
        if seg.no_speech_prob > 0.6:
            continue  # trecho provavelmente sem voz (instrumental) -- descarta
        for w in seg.words:
            palavras.append({"start": w.start, "end": w.end, "text": w.word.strip()})
    resultado[audio_file] = palavras
    print(f"  {len(palavras)} palavras detectadas")

with open("transcricoes.json", "w", encoding="utf-8") as f:
    json.dump(resultado, f, ensure_ascii=False)
PYEOF
python3 transcrever.py

# ---------- 2. Montar o áudio em loop até bater a duração alvo (igual ao original) ----------
echo "== Montando áudio em loop =="
ls audio_*.mp3 | sort > audio_list_base.txt
NUM_FAIXAS=$(wc -l < audio_list_base.txt)
DURACAO_FAIXAS=0
> duracoes_faixas.txt
while read -r f; do
  D=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f")
  echo "$f $D" >> duracoes_faixas.txt
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

# ---------- 2.5 Gerar legendas.ass (karaokê) repetindo/deslocando os timestamps a cada loop ----------
echo "== Gerando arquivo de legenda karaokê (.ass) =="
cat > gerar_ass.py << 'PYEOF'
import json

with open("transcricoes.json", encoding="utf-8") as f:
    transcricoes = json.load(f)

# ordem e duracao de cada faixa, na mesma ordem usada no loop de audio
faixas = []
with open("duracoes_faixas.txt") as f:
    for linha in f:
        nome, dur = linha.split()
        faixas.append((nome, float(dur)))

REPETICOES = int(open("repeticoes.txt").read().strip())
DURACAO_ALVO = float(open("duracao_alvo.txt").read().strip())

def fmt_ass_time(segundos):
    h = int(segundos // 3600)
    m = int((segundos % 3600) // 60)
    s = segundos % 60
    return f"{h}:{m:02d}:{s:05.2f}"

HEADER = """[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Karaoke,Baloo 2,72,&H0000FFFF,&H000000FF,&H00000000,&H64000000,1,0,0,0,100,100,0,0,1,4,2,2,80,80,90,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""

linhas_evento = []
tempo_global = 0.0  # onde essa repeticao da faixa comeca na linha do tempo final

def emitir_linha(grupo_palavras, offset_abs_inicio_faixa):
    """grupo_palavras: lista de palavras (com start/end relativos ao inicio da faixa).
    offset_abs_inicio_faixa: em que segundo da linha do tempo final essa faixa comeca."""
    if not grupo_palavras:
        return
    inicio_abs = offset_abs_inicio_faixa + grupo_palavras[0]["start"]
    fim_abs = offset_abs_inicio_faixa + grupo_palavras[-1]["end"]
    if inicio_abs >= DURACAO_ALVO:
        return
    fim_abs = min(fim_abs, DURACAO_ALVO)
    partes_karaoke = ""
    for p in grupo_palavras:
        dur_cs = max(1, int(round((p["end"] - p["start"]) * 100)))
        partes_karaoke += f"{{\\k{dur_cs}}}{p['text']} "
    linhas_evento.append(
        f"Dialogue: 0,{fmt_ass_time(inicio_abs)},{fmt_ass_time(fim_abs)},Karaoke,,0,0,0,,{partes_karaoke.strip()}"
    )

for rep in range(REPETICOES):
    if tempo_global >= DURACAO_ALVO:
        break
    for nome_faixa, duracao_faixa in faixas:
        if tempo_global >= DURACAO_ALVO:
            break
        palavras = transcricoes.get(nome_faixa, [])
        # agrupa palavras em linhas curtas (~6 palavras ou pausa > 0.6s entre elas)
        grupo = []
        ultimo_fim = None
        for p in palavras:
            if ultimo_fim is not None and (p["start"] - ultimo_fim) > 0.6 and grupo:
                emitir_linha(grupo, tempo_global)
                grupo = []
            grupo.append(p)
            ultimo_fim = p["end"]
            if len(grupo) >= 6:
                emitir_linha(grupo, tempo_global)
                grupo = []
        if grupo:
            emitir_linha(grupo, tempo_global)
        tempo_global += duracao_faixa

with open("legendas.ass", "w", encoding="utf-8") as f:
    f.write(HEADER)
    f.write("\n".join(linhas_evento))

print(f"{len(linhas_evento)} linhas de legenda geradas")
PYEOF
echo "$REPETICOES" > repeticoes.txt
echo "$DURACAO_ALVO_SEG" > duracao_alvo.txt
python3 gerar_ass.py

# ---------- 3. Montar o vídeo (imagens em loop com zoom + crossfade) ----------
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

# ---------- 4. Juntar áudio + vídeo + QUEIMAR LEGENDA (reencode, nao da mais pra usar -c:v copy) ----------
echo "== Juntando áudio, vídeo e legenda karaokê =="
ffmpeg -y -i video_sem_audio.mp4 -i audio_final.m4a -vf "ass=legendas.ass" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -shortest video_final.mp4 -loglevel error
echo "== Concluído =="
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 video_final.mp4
ls -la video_final.mp4

# ---------- 5. Gerar Shorts (2 cortes verticais 9:16) ----------
# NOTA: nesta primeira versao os Shorts NAO recebem legenda (video_final.mp4 aqui
# ja tem a legenda queimada, entao os cortes vao sair COM legenda tambem --
# isso e intencional para a v1; se nao quiser legenda nos Shorts, avisar que
# precisamos cortar de um video_final_sem_legenda.mp4 separado).
echo "== Gerando Shorts =="
SHORT_DUR=50
INICIO_SHORT_1=0
INICIO_SHORT_2=$(echo "$DURACAO_ALVO_SEG * 0.4" | bc | cut -d. -f1)
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

# ---------- 6. Gerar thumbnail customizada (igual ao original) ----------
echo "== Gerando thumbnail customizada =="
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
cat > make_thumbnail.py << 'PYEOF'
import sys
from PIL import Image, ImageDraw, ImageFont

def rounded_badge(base_img, text, font, xy_bottom_right, pad=26,
                   fill=(30, 20, 60, 235), text_color=(255, 255, 255)):
    tmp = Image.new("RGBA", base_img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(tmp)
    bbox = d.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    box_w, box_h = tw + pad * 2, th + pad * 2
    x2, y2 = xy_bottom_right
    x1, y1 = x2 - box_w, y2 - box_h
    d.rounded_rectangle([x1, y1, x2, y2], radius=box_h / 2, fill=fill)
    d.text((x1 + pad, y1 + pad - bbox[1]), text, font=font, fill=text_color)
    base_img.alpha_composite(tmp)

def main():
    template_path, duracao_texto, font_path, out_path = sys.argv[1:5]
    base = Image.open(template_path).convert("RGBA").resize((1280, 720))
    font_badge = ImageFont.truetype(font_path, 44)
    rounded_badge(base, duracao_texto, font_badge, xy_bottom_right=(1280 - 34, 720 - 28))
    base.convert("RGB").save(out_path, quality=92)

if __name__ == "__main__":
    main()
PYEOF
python3 make_thumbnail.py thumb_template.png "$DURACAO_TEXTO" "$FONT" thumbnail.jpg
echo "== Thumbnail gerada =="
ls -la thumbnail.jpg

# ---------- 7. Gerar vinheta de CTA e anexar ao final ----------
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
echo "== Vídeo final com CTA e legenda pronto =="
ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 video_final.mp4
ls -la video_final.mp4 thumbnail.jpg short_1.mp4 short_2.mp4
