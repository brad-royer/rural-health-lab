# HIE subscription receiver (Phase 3b.3). Tiny stdlib HTTP server; built rather
# than bind-mounted to avoid the WSL bind-mount fragility seen with HAPI.
FROM python:3.12-slim
COPY receiver.py /app/receiver.py
EXPOSE 9000
CMD ["python", "/app/receiver.py"]
