"""Camera XMP sidecars: find the one that belongs to a photo, and merge it with the Fix-locations sidecar.

A camera or editor (Lightroom, darktable, the camera itself) can leave `<photo>.xmp` or `<photo name without
extension>.xmp` next to the photo, holding the rating, title, description, keywords and sometimes GPS or a date.
Immich reads such a sidecar when it arrives with the upload as `sidecarData`, so the bridge sends it along.

Matching (the same rules as the phone app, build 300), inside the photo's own folder, ignoring case:
1. `<file name>.xmp`        DSC_0042.NEF.xmp -> DSC_0042.NEF
2. `<name without ext>.xmp` P1010001.xmp     -> P1010001.ORF (and P1010001.JPG, when both exist)

Merging with a Fix-locations sidecar: the camera's file is the base (rating, title, keywords, edits stay); the
place and time chosen on the Fix locations tab replace the camera's date and GPS; its note becomes the
description only when the camera has none. The originals on the NAS are never changed.
"""

from __future__ import annotations

import logging
import os
import xml.etree.ElementTree as ET

log = logging.getLogger(__name__)

MAX_BYTES = 4 * 1024 * 1024  # a camera sidecar is a few KB; anything this big is not one
XMP_WAIT_S = int(os.environ.get("XMP_WAIT_S", "45"))  # how long a fresh photo waits for its sidecar to arrive
RAW_EXTS = {"dng", "nef", "nrw", "orf", "rw2", "arw", "srf", "sr2", "cr2", "cr3", "crw", "raf", "pef", "srw", "x3f", "3fr",
            "iiq", "rwl", "erf", "kdc", "mrw", "mos", "dcr", "raw"}

NS = {
    "x": "adobe:ns:meta/",
    "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "exif": "http://ns.adobe.com/exif/1.0/",
    "photoshop": "http://ns.adobe.com/photoshop/1.0/",
    "dc": "http://purl.org/dc/elements/1.1/",
    "tiff": "http://ns.adobe.com/tiff/1.0/",
    "xmp": "http://ns.adobe.com/xap/1.0/",
    "xmpMM": "http://ns.adobe.com/xap/1.0/mm/",
    "crs": "http://ns.adobe.com/camera-raw-settings/1.0/",
    "lr": "http://ns.adobe.com/lightroom/1.0/",
    "aux": "http://ns.adobe.com/exif/1.0/aux/",
    "exifEX": "http://cipa.jp/exif/1.0/",
    "darktable": "http://darktable.sf.net/",
    "digiKam": "http://www.digikam.org/ns/1.0/",
}
for _p, _u in NS.items():
    ET.register_namespace(_p, _u)

RDF_DESC = f"{{{NS['rdf']}}}Description"
# what a Fix-locations sidecar decides; the camera's own values for these are replaced
FIX_DATE = {f"{{{NS['exif']}}}DateTimeOriginal", f"{{{NS['photoshop']}}}DateCreated"}
FIX_GPS = {f"{{{NS['exif']}}}GPSLatitude", f"{{{NS['exif']}}}GPSLongitude", f"{{{NS['exif']}}}GPSLatitudeRef",
           f"{{{NS['exif']}}}GPSLongitudeRef", f"{{{NS['exif']}}}GPSAltitude", f"{{{NS['exif']}}}GPSAltitudeRef",
           f"{{{NS['exif']}}}GPSVersionID", f"{{{NS['exif']}}}GPSTimeStamp", f"{{{NS['exif']}}}GPSDateStamp"}
FIX_NOTE = {f"{{{NS['dc']}}}description", f"{{{NS['tiff']}}}ImageDescription"}


def _ext(name: str) -> str:
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def find_camera_sidecar(path: str) -> str | None:
    """The camera/editor XMP next to this photo, or None. A sidecar is never itself a photo."""
    folder, name = os.path.split(path)
    if _ext(name) == "xmp":
        return None
    try:
        names = os.listdir(folder)
    except OSError:
        return None
    lower = {n.lower(): n for n in names if _ext(n) == "xmp"}
    for want in (name + ".xmp", name.rsplit(".", 1)[0] + ".xmp"):
        hit = lower.get(want.lower())
        if hit is not None:
            return os.path.join(folder, hit)
    return None


def folder_has_xmp(path: str) -> bool:
    try:
        return any(_ext(n) == "xmp" for n in os.listdir(os.path.dirname(path)))
    except OSError:
        return False


def may_get_sidecar(path: str) -> bool:
    """Worth waiting a little for a sidecar that is still uploading: a RAW photo, or a folder that has XMPs."""
    return _ext(os.path.basename(path)) in RAW_EXTS or folder_has_xmp(path)


def read_camera_sidecar(path: str) -> bytes | None:
    side = find_camera_sidecar(path)
    if side is None:
        return None
    try:
        if os.path.getsize(side) > MAX_BYTES:
            log.warning("sidecar too big to be one, not sent: %s", side)
            return None
        with open(side, "rb") as fh:
            return fh.read()
    except OSError as ex:
        log.warning("could not read sidecar %s: %s", side, ex)
        return None


def _descriptions(root: ET.Element) -> list[ET.Element]:
    return list(root.iter(RDF_DESC))


def _drop(desc: ET.Element, tags: set[str]) -> None:
    for attr in [a for a in desc.attrib if a in tags]:
        del desc.attrib[attr]
    for child in [c for c in desc if c.tag in tags]:
        desc.remove(child)


def _has(descs: list[ET.Element], tags: set[str]) -> bool:
    return any(any(a in tags for a in d.attrib) or any(c.tag in tags for c in d) for d in descs)


def merge(camera: bytes, fix: bytes | None) -> bytes:
    """One sidecar for the upload: the camera's, with the Fix-locations date/GPS (and note, if the camera has no
    description) put in. Returns the camera's bytes unchanged when there is nothing to merge, and the fix alone
    when the camera's file can't be read as XMP."""
    if fix is None:
        return camera
    try:
        cam_root = ET.fromstring(camera.strip().lstrip(b"\xef\xbb\xbf"))
    except ET.ParseError as ex:
        log.warning("camera sidecar is not readable XMP (%s); sending only the chosen place and time", ex)
        return fix
    fix_root = ET.fromstring(fix)
    cam_descs = _descriptions(cam_root)
    fix_descs = _descriptions(fix_root)
    if not cam_descs or not fix_descs:
        return fix
    fix_desc = fix_descs[0]
    fix_tags = {c.tag for c in fix_desc}
    replace = (FIX_DATE if fix_tags & FIX_DATE else set()) | (FIX_GPS if fix_tags & FIX_GPS else set())
    keep_note = _has(cam_descs, FIX_NOTE)
    for d in cam_descs:
        _drop(d, replace)
    target = cam_descs[0]
    for child in fix_desc:
        if child.tag in FIX_NOTE and keep_note:
            continue
        target.append(child)
    body = ET.tostring(cam_root, encoding="unicode")
    if cam_root.tag == RDF_DESC or cam_root.tag.endswith("}RDF"):
        body = f"<x:xmpmeta xmlns:x='{NS['x']}'>{body}</x:xmpmeta>"
    return ("<?xpacket begin='﻿' id='W5M0MpCehiHzreSzNTczkc9d'?>\n" + body + "\n<?xpacket end='w'?>\n").encode("utf-8")
