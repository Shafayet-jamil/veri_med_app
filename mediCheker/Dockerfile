# MediChecker backend: Flask API + EasyOCR (CPU only).
#
#   docker build -t medichecker-api mediCheker
#   docker run -p 8080:8080 -e MEDICHECKER_API_KEY=<your key> medichecker-api
#
# Works on any container host (Google Cloud Run, Render, Railway, a VPS ...).
# The host should provide HTTPS in front of it.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080 \
    MEDICHECKER_TRUST_PROXY=1 \
    EASYOCR_MODULE_PATH=/opt/easyocr

# Shared libraries OpenCV needs at runtime.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# CPU-only PyTorch is much smaller than the default CUDA build.
COPY requirements.txt .
RUN pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu \
    && pip install -r requirements.txt

# Download the EasyOCR models at build time so the first scan is not slow.
RUN python -c "import easyocr; easyocr.Reader(['en'], gpu=False)"

COPY *.py ./
COPY excelFile ./excelFile

RUN useradd --create-home appuser
USER appuser

EXPOSE 8080
CMD ["python", "server.py"]
