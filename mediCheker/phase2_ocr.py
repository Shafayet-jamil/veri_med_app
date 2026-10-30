import cv2
import easyocr
import os
import re
import tempfile


def preprocess_foil_image(image_path):


    img = cv2.imread(image_path)

    if img is None:
        raise FileNotFoundError(f"Image not found: {image_path}")

    height, width = img.shape[:2]
    upscaled = cv2.resize(
        img, (width * 3, height * 3), interpolation=cv2.INTER_LANCZOS4
    )

    gray = cv2.cvtColor(upscaled, cv2.COLOR_BGR2GRAY)


    bilateral = cv2.bilateralFilter(gray, d=9, sigmaColor=75, sigmaSpace=75)

    clahe = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8,8))
    contrast_img = clahe.apply(bilateral)

    gaussian_blur = cv2.GaussianBlur(contrast_img, (0, 0), sigmaX=3)
    sharpened = cv2.addWeighted(contrast_img, 1.5, gaussian_blur, -0.5, 0)

    _, otsu = cv2.threshold(sharpened, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)

    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (2, 2))
    cleaned = cv2.morphologyEx(otsu, cv2.MORPH_OPEN, kernel, iterations=1)

    file_descriptor, temp_path = tempfile.mkstemp(suffix=".png")
    os.close(file_descriptor)
    if not cv2.imwrite(temp_path, cleaned):
        os.remove(temp_path)
        raise OSError("Could not write the preprocessed medicine image.")
    return temp_path


def normalize_ma_number(ma_number: str) -> str:


    tablet_pattern = re.compile(r'^(\d+)-(\d{3})-(\d+)$')
    match = tablet_pattern.match(ma_number.strip())
    if match:
        prefix, middle, suffix = match.groups()
        return f"{prefix}-0{middle}-{suffix}"

    return ma_number


def run_easyocr(image_path):
    print("--Phase 2: Running Image Preprocessing & OCR--")

    clean_image_path = preprocess_foil_image(image_path)
    try:
        reader = easyocr.Reader(['en'], gpu=False)
        print(f"Running OCR on the image...'{image_path}'")
        result = reader.readtext(
            clean_image_path, text_threshold=0.3, low_text=0.2, slope_ths=0.3,
            min_size=10, width_ths=0.8
        )
        print("Extracted text result:")
        extracted_string = []
        for (bbox, text, prob) in result:
            if prob > 0.20:
                extracted_string.append(text)
                print(f"[Confidence: {prob: .2f}] -> {text}")

        normalized_results = []
        ma_pattern = re.compile(r'\d+-\d+-\d+')
        for text in extracted_string:
            if ma_pattern.search(text):
                normalized = normalize_ma_number(text)
                if normalized != text:
                    print(f"[MA Normalized] '{text}' -> '{normalized}'")
                normalized_results.append(normalized)
            else:
                normalized_results.append(text)
        return normalized_results
    finally:
        if os.path.exists(clean_image_path):
            os.remove(clean_image_path)


if __name__ == "__main__":
    sample_image = os.path.join("dataset", "sample-4.jpeg")


    if os.path.exists(sample_image):
        run_easyocr(sample_image)
    else:
        print(f"Image not found: {sample_image}")