# HIE OAuth gateway (Phase 3b.6). Validates Keycloak JWTs and reverse-proxies
# to HAPI. cryptography for RS256 verification (no PyJWT).
FROM python:3.12-slim
RUN pip install --no-cache-dir cryptography
COPY gateway.py /app/gateway.py
EXPOSE 8080
CMD ["python", "/app/gateway.py"]
