FROM python:3.12-alpine

# exiftool reads capture time/GPS for the Fix locations tab (the same tool Immich uses); ffmpeg makes its previews
RUN apk add --no-cache exiftool ffmpeg && pip install --no-cache-dir requests==2.32.*

WORKDIR /app
COPY bridge/ /app/bridge/

# State DB lives here — mount a volume to persist it across recreates.
VOLUME /data
EXPOSE 8099

HEALTHCHECK --interval=60s --timeout=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8099/healthz || exit 1

CMD ["python", "-m", "bridge"]
