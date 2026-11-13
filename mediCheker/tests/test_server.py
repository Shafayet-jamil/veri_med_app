import io
import os

import pytest

import server

NAPA_DAR = "186-0479-006"


@pytest.fixture
def client(monkeypatch):
    server.app.config["TESTING"] = True
    # Defaults for every test: no API key, no scan limit.
    monkeypatch.setattr(server, "API_KEY", "")
    monkeypatch.setattr(server, "scan_limiter", server._RateLimiter(0))
    # Curated interaction list only, whether or not DDInter is downloaded.
    monkeypatch.setattr(server, "interactions_df",
                        server.load_interactions(ddinter_path=None))
    with server.app.test_client() as client:
        yield client


@pytest.fixture
def fake_ocr(monkeypatch):
    """Replace EasyOCR with a stub that returns the given lines of text."""
    def install(lines):
        monkeypatch.setattr(server, "run_easyocr", lambda path: list(lines))
    return install


def image_upload(name="label.jpg", data=b"fake image bytes"):
    return {"image": (io.BytesIO(data), name)}


def test_health_check(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.get_json()["status"] == "online"


# ── /verify-license ──────────────────────────────────────────────────────────

def test_verify_license_found(client):
    response = client.get(f"/verify-license?dar_number={NAPA_DAR}")
    body = response.get_json()
    assert response.status_code == 200
    assert body["match_found"] is True
    assert body["brand_name"] == "Napa"
    assert body["manufacturer"] == "Beximco Pharmaceuticals Ltd."
    assert body["mfg_license_non_biological"] == "379"


def test_verify_license_accepts_json_body(client):
    response = client.post("/verify-license", json={"dar_number": NAPA_DAR})
    assert response.status_code == 200
    assert response.get_json()["brand_name"] == "Napa"


def test_verify_license_accepts_short_printed_number(client):
    response = client.get("/verify-license?dar_number=353-41-023")
    body = response.get_json()
    assert response.status_code == 200
    assert body["brand_name"] == "Furoclav 500"
    assert body["dar_number"] == "353-0041-023"   # the registered form


def test_verify_license_not_found(client):
    response = client.get("/verify-license?dar_number=000-0000-000")
    assert response.status_code == 404
    assert response.get_json()["match_found"] is False


def test_verify_license_missing_parameter(client):
    response = client.get("/verify-license")
    assert response.status_code == 400


# ── /scan-medicine ───────────────────────────────────────────────────────────

def test_scan_without_image_is_rejected(client):
    response = client.post("/scan-medicine", data={})
    assert response.status_code == 400


def test_scan_genuine_label(client, fake_ocr):
    fake_ocr(["Napa", "Paracetamol 500 mg", "Beximco Pharmaceuticals Ltd.",
              f"DAR No. {NAPA_DAR}", "Mfg. Lic. No. 379"])
    response = client.post("/scan-medicine", data=image_upload(),
                           content_type="multipart/form-data")
    body = response.get_json()

    assert response.status_code == 200
    assert body["match_found"] is True
    assert body["dar_number"] == NAPA_DAR
    assert body["manufacturer"] == "Beximco Pharmaceuticals Ltd."
    assert body["match_type"] == "medicine"
    assert body["verification"]["verdict"] == "likely_genuine"
    assert "Napa | Paracetamol 500 mg" in body["extracted_text"]


def test_scan_partial_label_is_not_called_counterfeit(client, fake_ocr):
    # Real case (sample-10): only "MA No. 353-41-023" is readable.
    fake_ocr(["MA No. 353-41-023", "Antibiotic"])
    body = client.post("/scan-medicine", data=image_upload(),
                       content_type="multipart/form-data").get_json()

    assert body["brand_name"] == "Furoclav 500"
    assert body["dar_number"] == "353-0041-023"
    assert body["verification"]["verdict"] == "partial_match"


def test_scan_manufacturer_only(client, fake_ocr):
    fake_ocr(["Mfg. Lic. No. 379"])
    body = client.post("/scan-medicine", data=image_upload(),
                       content_type="multipart/form-data").get_json()

    assert body["match_type"] == "manufacturer"
    assert body["manufacturer"] == "Beximco Pharmaceuticals Ltd."
    assert body["brand_name"] == ""
    assert body["verification"]["verdict"] == "manufacturer_only"


def test_scan_unreadable_label(client, fake_ocr):
    fake_ocr(["blurry", "nothing useful"])
    response = client.post("/scan-medicine", data=image_upload(),
                           content_type="multipart/form-data")
    body = response.get_json()

    assert response.status_code == 200
    assert body["match_found"] is False
    assert body["match_type"] == "none"
    assert body["verification"]["verdict"] == "no_record"
    assert "Lookup tab" in body["verification"]["verdict_description"]


def test_scan_removes_temp_file(client, monkeypatch):
    seen = {}

    def fake(path):
        seen["path"] = path
        return []

    monkeypatch.setattr(server, "run_easyocr", fake)
    client.post("/scan-medicine", data=image_upload(),
                content_type="multipart/form-data")
    assert not os.path.exists(seen["path"])


def test_scan_ocr_failure_returns_500(client, monkeypatch):
    def broken(path):
        raise RuntimeError("OCR crashed")

    monkeypatch.setattr(server, "run_easyocr", broken)
    response = client.post("/scan-medicine", data=image_upload(),
                           content_type="multipart/form-data")
    assert response.status_code == 500
    # Internal details stay in the server log, not in the response.
    assert "OCR crashed" not in response.get_json()["error"]


def test_scan_unreadable_image_returns_400(client):
    # Real OCR entry point: the bytes are not an image, so it fails before
    # the EasyOCR model is ever loaded.
    response = client.post("/scan-medicine",
                           data=image_upload(data=b"definitely not a jpeg"),
                           content_type="multipart/form-data")
    assert response.status_code == 400
    assert "not a readable image" in response.get_json()["error"]


def test_scan_upload_too_large(client, monkeypatch, fake_ocr):
    fake_ocr([])
    monkeypatch.setitem(server.app.config, "MAX_CONTENT_LENGTH", 1024)
    response = client.post("/scan-medicine",
                           data=image_upload(data=b"x" * 4096),
                           content_type="multipart/form-data")
    assert response.status_code == 413
    assert "too large" in response.get_json()["error"]


def test_scan_rate_limit(client, monkeypatch, fake_ocr):
    fake_ocr([])
    monkeypatch.setattr(server, "scan_limiter", server._RateLimiter(2))
    codes = [
        client.post("/scan-medicine", data=image_upload(),
                    content_type="multipart/form-data").status_code
        for _ in range(3)
    ]
    assert codes == [200, 200, 429]


def test_rate_limiter_window_expires(monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(server.time, "monotonic", lambda: clock[0])
    limiter = server._RateLimiter(1, window_seconds=60)
    assert limiter.allow("a") is True
    assert limiter.allow("a") is False
    assert limiter.allow("b") is True   # other clients are unaffected
    clock[0] += 61
    assert limiter.allow("a") is True


# ── API key ──────────────────────────────────────────────────────────────────

TEST_KEY = "test-key-123"


def test_api_key_required_when_configured(client, monkeypatch):
    monkeypatch.setattr(server, "API_KEY", TEST_KEY)
    url = f"/verify-license?dar_number={NAPA_DAR}"

    assert client.get(url).status_code == 401
    assert client.get(url, headers={"X-API-Key": "wrong"}).status_code == 401
    assert client.get(url, headers={"X-API-Key": TEST_KEY}).status_code == 200


def test_health_check_needs_no_api_key(client, monkeypatch):
    monkeypatch.setattr(server, "API_KEY", TEST_KEY)
    assert client.get("/").status_code == 200


def test_unknown_route_returns_json_404(client):
    response = client.get("/does-not-exist")
    assert response.status_code == 404
    assert "error" in response.get_json()


# ── Interactions ─────────────────────────────────────────────────────────────

def test_medicine_names(client):
    response = client.get("/medicine-names")
    assert response.status_code == 200
    names = response.get_json()["medicines"]
    assert any(m["trade_name"] == "Napa" for m in names)


def test_check_interactions(client):
    response = client.post("/check-interactions",
                           json={"medicines": ["Warfarin", "Aspirin"]})
    body = response.get_json()
    assert response.status_code == 200
    assert body["interactions_found"] is True
    assert body["interaction_count"] == 1
    assert body["interactions"][0]["source"] == "MediChecker curated list"
    assert [s["name"] for s in body["sources"]] == ["MediChecker curated list"]


@pytest.mark.parametrize("payload", [
    {},
    {"medicines": ["Warfarin"]},
    {"medicines": "Warfarin, Aspirin"},
    {"medicines": ["Warfarin", 42]},
    {"medicines": ["Warfarin", "  "]},
    {"medicines": [f"Drug {i}" for i in range(21)]},
])
def test_check_interactions_rejects_bad_input(client, payload):
    response = client.post("/check-interactions", json=payload)
    assert response.status_code == 400


# ── Brand-name spelling ──────────────────────────────────────────────────────

def scan(client):
    return client.post("/scan-medicine", data=image_upload(),
                       content_type="multipart/form-data").get_json()


def test_scan_identifies_medicine_by_brand_name(client, fake_ocr):
    # No DAR / MA or MFG licence number readable: only the front of the pack.
    fake_ocr(["Napa", "Paracetamol 500 mg Tablet", "Beximco Pharmaceuticals Ltd."])
    body = scan(client)
    assert body["match_found"] is True
    assert body["match_type"] == "brand_name"
    assert body["brand_name"] == "Napa"
    assert body["name_check"]["status"] == "exact"
    assert body["verification"]["verdict"] == "likely_genuine"


def test_scan_misspelled_brand_is_likely_fake(client, fake_ocr):
    fake_ocr(["Nappa", "Paracetamol 500 mg Tablet", "Beximco Pharmaceuticals Ltd."])
    body = scan(client)
    assert body["brand_name"] == "Napa"            # the medicine it imitates
    assert body["name_check"]["status"] == "misspelled"
    assert body["name_check"]["read_name"] == "nappa"
    verification = body["verification"]
    assert verification["verdict"] == "name_misspelled"
    assert "Nappa".lower() in verification["verdict_description"].lower()


def test_scan_misspelled_brand_with_real_numbers_is_likely_fake(client, fake_ocr):
    # The registration numbers are copied from the real pack, but the name
    # is printed wrong.
    fake_ocr(["Nappa", "Paracetamol 500 mg", "Beximco Pharmaceuticals Ltd.",
              f"DAR No. {NAPA_DAR}", "Mfg. Lic. No. 379"])
    body = scan(client)
    assert body["match_type"] == "medicine"
    assert body["verification"]["verdict"] == "name_misspelled"


def test_scan_numbers_of_another_brand_are_flagged(client, fake_ocr):
    # Biltin printed on the pack, but the DAR number belongs to Napa.
    fake_ocr(["Biltin", "Bilastine 20 mg Tablet", "Eskayef Pharmaceuticals",
              f"DAR No. {NAPA_DAR}"])
    body = scan(client)
    brand = next(c for c in body["verification"]["checks"]
                 if c["field"] == "Brand / Trade Name")
    assert brand["status"] == "mismatch"
    assert body["verification"]["verdict"] in ("suspicious", "likely_counterfeit")


def test_scan_unregistered_medicine_is_likely_fake(client, fake_ocr):
    fake_ocr(["Zorbatex 500", "Paracetamol tablet", "Healwell Pharma Ltd",
              "Keep away from children"])
    body = scan(client)
    assert body["match_found"] is False
    assert body["verification"]["verdict"] == "not_registered"
    assert "fake" in body["verification"]["verdict_label"].lower()


def test_verify_name_found(client):
    response = client.get("/verify-name?name=Napa")
    body = response.get_json()
    assert response.status_code == 200
    assert body["brand_name"] == "Napa"
    assert body["manufacturer"] == "Beximco Pharmaceuticals Ltd."


def test_verify_name_not_registered_suggests_spelling(client):
    response = client.get("/verify-name?name=Nappa")
    body = response.get_json()
    assert response.status_code == 404
    assert body["match_found"] is False
    assert "Napa" in body["name_check"]["suggestions"]


def test_verify_name_missing_parameter(client):
    assert client.get("/verify-name").status_code == 400
