"""Camera XMP sidecars travel with their photo; a Fix-locations place and time is merged in."""

import json
import logging
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET

import pytest

from bridge import sidecars
from bridge.geofix import build_sidecar
from tests.stub_immich import StubImmich
from tests.test_worker import make_worker, write_file

CAMERA_XMP = b"""<?xpacket begin='\xef\xbb\xbf' id='W5M0MpCehiHzreSzNTczkc9d'?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:exif="http://ns.adobe.com/exif/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
    xmp:Rating="4"
    exif:GPSLatitude="10,0.000000N"
    photoshop:DateCreated="2020-01-01T00:00:00">
   <exif:DateTimeOriginal>2020-01-01T00:00:00</exif:DateTimeOriginal>
   <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Sunset dive</rdf:li></rdf:Alt></dc:title>
   <dc:description><rdf:Alt><rdf:li xml:lang="x-default">My caption</rdf:li></rdf:Alt></dc:description>
   <dc:subject><rdf:Bag><rdf:li>snorkel</rdf:li><rdf:li>reef</rdf:li></rdf:Bag></dc:subject>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end='w'?>
"""


def _fix():
    from datetime import datetime

    return build_sidecar(datetime(2026, 5, 1, 14, 3, 22), 540, 35.0116, 135.7681, "estimated from the file counter", True)


def test_the_sidecar_is_found_by_full_name_first_then_by_stem(tmp_path):
    (tmp_path / "DSC_0042.NEF").write_bytes(b"raw")
    (tmp_path / "DSC_0042.NEF.XMP").write_bytes(b"x")
    (tmp_path / "P1010001.ORF").write_bytes(b"raw")
    (tmp_path / "P1010001.JPG").write_bytes(b"jpg")
    (tmp_path / "p1010001.xmp").write_bytes(b"x")
    (tmp_path / "IMG_1.jpg").write_bytes(b"jpg")
    assert sidecars.find_camera_sidecar(str(tmp_path / "DSC_0042.NEF")).endswith("DSC_0042.NEF.XMP")
    assert sidecars.find_camera_sidecar(str(tmp_path / "P1010001.ORF")).endswith("p1010001.xmp")
    assert sidecars.find_camera_sidecar(str(tmp_path / "P1010001.JPG")).endswith("p1010001.xmp")  # RAW+JPG pair: both
    assert sidecars.find_camera_sidecar(str(tmp_path / "IMG_1.jpg")) is None
    assert sidecars.find_camera_sidecar(str(tmp_path / "p1010001.xmp")) is None  # a sidecar has no sidecar


def test_the_camera_sidecar_keeps_its_rating_and_keywords_and_takes_the_chosen_place_and_time():
    out = sidecars.merge(CAMERA_XMP, _fix())
    root = ET.fromstring(out.split(b"?>", 1)[1].rsplit(b"<?xpacket", 1)[0])
    text = out.decode()
    assert 'Rating="4"' in text and "snorkel" in text and "Sunset dive" in text
    assert "My caption" in text and "estimated from the file counter" not in text  # the camera's own caption wins
    assert "2020-01-01" not in text and "10,0.000000N" not in text  # the camera's date and GPS are replaced
    assert "2026-05-01T14:03:22+09:00" in text and "35,0.696000N" in text
    assert root.tag == "{adobe:ns:meta/}xmpmeta"


def test_without_a_place_to_merge_the_camera_file_goes_as_it_is_and_a_broken_one_is_left_out():
    assert sidecars.merge(CAMERA_XMP, None) == CAMERA_XMP
    assert sidecars.merge(b"<not xmp", _fix()) == _fix()


@pytest.mark.skipif(shutil.which("exiftool") is None, reason="needs the real exiftool")
def test_real_exiftool_reads_the_merged_sidecar(tmp_path):
    p = tmp_path / "merged.xmp"
    p.write_bytes(sidecars.merge(CAMERA_XMP, _fix()))
    tags = json.loads(subprocess.run(["exiftool", "-json", "-n", "-Rating", "-Subject", "-Title", "-Description",
                                      "-DateTimeOriginal", "-GPSLatitude", "-GPSLongitude", str(p)],
                                     capture_output=True, check=True).stdout)[0]
    assert tags["Rating"] == 4 and tags["Subject"] == ["snorkel", "reef"] and tags["Title"] == "Sunset dive"
    assert tags["Description"] == "My caption"
    assert tags["DateTimeOriginal"].startswith("2026:05:01 14:03:22")
    assert abs(tags["GPSLatitude"] - 35.0116) < 1e-4 and abs(tags["GPSLongitude"] - 135.7681) < 1e-4


def test_a_raw_photo_is_uploaded_with_its_camera_sidecar(tmp_path, monkeypatch):
    monkeypatch.setattr(sidecars, "XMP_WAIT_S", 0)
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        worker._allowed = {"jpg", "orf"}
        photo = write_file(tmp_path, "trip/P1010001.ORF", b"raw bytes")
        write_file(tmp_path, "trip/P1010001.xmp", CAMERA_XMP)
        worker._process(photo)
        assert state.get(photo).status == "imported"
        assert len(stub.uploads) == 1 and "snorkel" in stub.uploads[0]["sidecar"]  # the stub refuses a 'filename' field


def test_a_fresh_raw_waits_for_its_sidecar_then_goes_with_it(tmp_path, monkeypatch):
    monkeypatch.setattr(sidecars, "XMP_WAIT_S", 1)
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        worker._allowed = {"jpg", "orf"}
        photo = write_file(tmp_path, "trip/P1010002.ORF", b"raw two")
        worker._process(photo)
        assert stub.uploads == [] and state.get(photo) is None  # waiting, nothing recorded
        write_file(tmp_path, "trip/P1010002.xmp", CAMERA_XMP)  # the sidecar finishes uploading
        assert worker._queue.get(timeout=3)[2] == photo  # put back in the queue after the wait
        worker._process(photo)
        assert len(stub.uploads) == 1 and "snorkel" in stub.uploads[0]["sidecar"]


def test_a_phone_photo_in_a_folder_without_sidecars_does_not_wait(tmp_path, monkeypatch):
    monkeypatch.setattr(sidecars, "XMP_WAIT_S", 60)
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        photo = write_file(tmp_path, "phone/IMG_1.jpg", b"jpg")
        worker._process(photo)
        assert len(stub.uploads) == 1 and stub.uploads[0]["sidecar"] is None


def test_a_raw_with_no_sidecar_is_imported_after_the_wait(tmp_path, monkeypatch):
    monkeypatch.setattr(sidecars, "XMP_WAIT_S", 1)
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        worker._allowed = {"orf"}
        photo = write_file(tmp_path, "trip/P1010003.ORF", b"raw three")
        worker._process(photo)
        assert worker._queue.get(timeout=3)[2] == photo
        time.sleep(0.05)
        worker._process(photo)
        assert len(stub.uploads) == 1 and stub.uploads[0]["sidecar"] is None


def test_a_sidecar_that_arrives_too_late_is_reported(tmp_path, monkeypatch, caplog):
    monkeypatch.setattr(sidecars, "XMP_WAIT_S", 0)
    with StubImmich() as stub:
        worker, state, _ = make_worker(tmp_path, stub)
        worker._allowed = {"orf"}
        photo = write_file(tmp_path, "trip/P1010004.ORF", b"raw four")
        worker._process(photo)
        side = write_file(tmp_path, "trip/P1010004.xmp", CAMERA_XMP)
        with caplog.at_level(logging.WARNING):
            worker._process(side)
        assert "arrived after P1010004.ORF was imported" in caplog.text
        assert state.get(side).status == "skipped" and len(stub.uploads) == 1
