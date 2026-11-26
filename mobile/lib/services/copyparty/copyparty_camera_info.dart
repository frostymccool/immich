import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// What a camera file says about itself: which camera, when, where. Every field is optional.
class CameraFileInfo {
  final String? make;
  final String? model;
  final String? serial;

  /// The shooting day as `YYYY-MM-DD` (the camera's wall clock), when the file states it.
  final String? day;
  final double? lat;
  final double? lon;

  const CameraFileInfo({this.make, this.model, this.serial, this.day, this.lat, this.lon});

  static const empty = CameraFileInfo();

  bool get hasGps => lat != null && lon != null;

  /// Fills the gaps in this with [other] (this wins).
  CameraFileInfo merge(CameraFileInfo other) => CameraFileInfo(
    make: make ?? other.make,
    model: model ?? other.model,
    serial: serial ?? other.serial,
    day: day ?? other.day,
    lat: hasGps ? lat : other.lat,
    lon: hasGps ? lon : other.lon,
  );

  @override
  String toString() =>
      'CameraFileInfo(make: $make, model: $model, serial: ${serial == null ? null : 'set'}, day: $day, '
      'gps: $hasGps)';
}

/// Reads the camera model, shooting day and GPS from photo EXIF and from the Insta360 trailer at the end
/// of .insv/.mp4/.insp files. Reads only small parts of each file (the first 256 KiB of a photo, the
/// trailer's index and info record of a video), never the gyro data or the video itself.
class CameraInfoReader {
  // RAW: DNG/NEF/ARW/CR2 are TIFF files; Olympus ORF and Panasonic RW2 are TIFF with their own header mark.
  static const _photoExt = {'jpg', 'jpeg', 'insp', 'dng', 'nef', 'orf', 'arw', 'cr2', 'rw2'};
  static const _videoExt = {'insv', 'mp4', 'mov'};
  static const exifReadBytes = 256 * 1024;

  /// The Insta360 trailer ends with this ASCII text.
  static const insta360Magic = '8db42d694ccc418790edff439fe026bf';

  static String _ext(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }

  static bool isPhoto(String path) => _photoExt.contains(_ext(path));
  static bool isVideo(String path) => _videoExt.contains(_ext(path));

  /// Reads one file. Never throws: an unreadable file gives [CameraFileInfo.empty] plus the name's date.
  Future<CameraFileInfo> read(String path) async {
    final name = path.substring(path.lastIndexOf('/') + 1);
    var info = CameraFileInfo(day: dayFromFilename(name));
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      if (isPhoto(path)) {
        final head = await raf.read(exifReadBytes);
        info = info.merge(parseExif(head));
      }
      if (isPhoto(path) || isVideo(path)) {
        info = info.merge(await readInsta360Trailer(raf) ?? CameraFileInfo.empty);
      }
    } catch (_) {
      // Unreadable: keep what the name says.
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
    return info;
  }

  /// `VID_20260502_143012_00_057.insv` → `2026-05-02` (Insta360 and similar names hold the camera's wall clock).
  static String? dayFromFilename(String name) {
    // Insta360 `VID_20260502_143012_…`, DJI `DJI_20260502143012_0001_D.MP4`.
    final m =
        RegExp(r'^[A-Za-z]{2,4}_(\d{4})(\d{2})(\d{2})_\d{6}_').firstMatch(name) ??
        RegExp(r'^[A-Za-z]{2,4}_(\d{4})(\d{2})(\d{2})\d{6}_').firstMatch(name);
    if (m == null) {
      return null;
    }
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) {
      return null;
    }
    return '${m.group(1)}-${m.group(2)}-${m.group(3)}';
  }

  // ---------------------------------------------------------------------------
  // EXIF (JPEG APP1 or a bare TIFF such as DNG)
  // ---------------------------------------------------------------------------

  /// Make, Model, BodySerialNumber, DateTimeOriginal (day) and GPS from the first bytes of a photo.
  static CameraFileInfo parseExif(Uint8List bytes) {
    try {
      final tiff = _findTiff(bytes);
      if (tiff == null) {
        return CameraFileInfo.empty;
      }
      return _Tiff(bytes, tiff).read();
    } catch (_) {
      return CameraFileInfo.empty;
    }
  }

  static bool _rawMark(int c2, int c3) => (c2 == 0x52 && (c3 == 0x4f || c3 == 0x53)) || (c2 == 0x55 && c3 == 0);

  static int? _findTiff(Uint8List b) {
    if (b.length >= 4 &&
        ((b[0] == 0x49 && b[1] == 0x49 && ((b[2] == 42 && b[3] == 0) || _rawMark(b[2], b[3]))) ||
            (b[0] == 0x4d && b[1] == 0x4d && ((b[2] == 0 && b[3] == 42) || (b[2] == 0x4f && b[3] == 0x52))))) {
      return 0; // TIFF / DNG / NEF / ARW / CR2, Olympus ORF ("IIRO", "IIRS", "MMOR"), Panasonic RW2 ("IIU")
    }
    if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) {
      return null;
    }
    var i = 2;
    while (i + 4 <= b.length) {
      if (b[i] != 0xFF) {
        return null;
      }
      final marker = b[i + 1];
      if (marker == 0xD9 || marker == 0xDA) {
        return null; // end of image / start of scan: no EXIF before the pixels
      }
      final len = (b[i + 2] << 8) | b[i + 3];
      if (len < 2) {
        return null;
      }
      if (marker == 0xE1 &&
          i + 10 <= b.length &&
          b[i + 4] == 0x45 &&
          b[i + 5] == 0x78 &&
          b[i + 6] == 0x69 &&
          b[i + 7] == 0x66 &&
          b[i + 8] == 0 &&
          b[i + 9] == 0) {
        return i + 10;
      }
      i += 2 + len;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Insta360 trailer
  // ---------------------------------------------------------------------------

  /// The model, serial and firmware record (id 0x101) of the Insta360 trailer, following exiftool's
  /// `Image::ExifTool::QuickTimeStream::ProcessInsta360`: the last 78 bytes are the last record's 6-byte
  /// footer (`uint16 id, uint32 length`, little-endian), the trailer length at byte 38, and the magic in the
  /// last 32 bytes. Records are walked backwards by their footers (data never read), or located through the
  /// directory record (id 0) when there is one. Returns null when the file has no trailer.
  static Future<CameraFileInfo?> readInsta360Trailer(RandomAccessFile raf) async {
    final len = await raf.length();
    if (len < 78) {
      return null;
    }
    await raf.setPosition(len - 78);
    final tail = await raf.read(78);
    if (tail.length != 78 || ascii.decode(tail.sublist(46), allowInvalid: true) != insta360Magic) {
      return null;
    }
    final t = ByteData.sublistView(tail);
    final trailerLen = t.getUint32(38, Endian.little);
    if (trailerLen < 78 || trailerLen > len) {
      return null;
    }
    final trailerStart = len - trailerLen;
    var id = t.getUint16(0, Endian.little);
    var recLen = t.getUint32(2, Endian.little);
    var end = len - 78; // the current record's data ends where its footer starts
    for (var guard = 0; guard < 512; guard++) {
      final start = end - recLen;
      if (start < trailerStart) {
        return null;
      }
      if (id == 0x101) {
        return _parseInfoRecord(await _readAt(raf, start, math.min(recLen, 4096)));
      }
      if (id == 0 && recLen >= 10 && recLen <= 65536) {
        final dir = ByteData.sublistView(await _readAt(raf, start, recLen));
        for (var p = 0; p + 10 <= dir.lengthInBytes; p += 10) {
          final rid = dir.getUint16(p, Endian.little);
          final siz = dir.getUint32(p + 2, Endian.little);
          final off = dir.getUint32(p + 6, Endian.little);
          if (rid == 0x101 && siz > 0 && off + siz < trailerLen) {
            return _parseInfoRecord(await _readAt(raf, trailerStart + off, math.min(siz, 4096)));
          }
        }
      }
      if (start - 6 < trailerStart) {
        return null;
      }
      final footer = ByteData.sublistView(await _readAt(raf, start - 6, 6));
      if (footer.lengthInBytes != 6) {
        return null;
      }
      id = footer.getUint16(0, Endian.little);
      recLen = footer.getUint32(2, Endian.little);
      end = start - 6;
    }
    return null;
  }

  static Future<Uint8List> _readAt(RandomAccessFile raf, int pos, int n) async {
    await raf.setPosition(pos);
    return raf.read(n);
  }

  /// Record 0x101: entries of (tag byte, length byte, value); 0x0a serial, 0x12 model, 0x1a firmware.
  static CameraFileInfo _parseInfoRecord(Uint8List b) {
    String? serial;
    String? model;
    var p = 0;
    for (var i = 0; i < 8 && p + 2 <= b.length; i++) {
      final tag = b[p];
      final n = b[p + 1];
      if (p + 2 + n > b.length) {
        break;
      }
      final value = utf8.decode(b.sublist(p + 2, p + 2 + n), allowMalformed: true).replaceAll('\u0000', '').trim();
      if (tag == 0x0a) {
        serial = value;
      } else if (tag == 0x12) {
        model = value;
      }
      p += 2 + n;
    }
    return CameraFileInfo(
      make: model == null ? null : 'Insta360',
      model: model == null || model.isEmpty ? null : model,
      serial: serial == null || serial.isEmpty ? null : serial,
    );
  }
}

/// Minimal TIFF reader for the few EXIF tags needed. Every offset is bounds-checked.
class _Tiff {
  final Uint8List b;
  final int base;
  late final Endian e;

  _Tiff(this.b, this.base);

  int _u16(int o) => ByteData.sublistView(b, o, o + 2).getUint16(0, e);
  int _u32(int o) => ByteData.sublistView(b, o, o + 4).getUint32(0, e);

  CameraFileInfo read() {
    e = b[base] == 0x49 ? Endian.little : Endian.big;
    final ifd0 = base + _u32(base + 4);
    final t0 = _entries(ifd0);
    final make = _ascii(t0[0x010F]);
    final model = _ascii(t0[0x0110]);
    String? day;
    String? serial;
    final exifPtr = t0[0x8769];
    if (exifPtr != null) {
      final ex = _entries(base + exifPtr.value);
      day = _dayOf(_ascii(ex[0x9003]) ?? _ascii(ex[0x9004]));
      serial = _ascii(ex[0xA431]);
    }
    day ??= _dayOf(_ascii(t0[0x0132]));
    double? lat;
    double? lon;
    final gpsPtr = t0[0x8825];
    if (gpsPtr != null) {
      final g = _entries(base + gpsPtr.value);
      lat = _coord(g[2], _ascii(g[1]));
      lon = _coord(g[4], _ascii(g[3]));
      if (lat == null || lon == null || (lat == 0 && lon == 0) || lat.abs() > 90 || lon.abs() > 180) {
        lat = null;
        lon = null;
      }
    }
    return CameraFileInfo(make: make, model: model, serial: serial, day: day, lat: lat, lon: lon);
  }

  Map<int, _Entry> _entries(int off) {
    final out = <int, _Entry>{};
    if (off < base || off + 2 > b.length) {
      return out;
    }
    final n = _u16(off);
    for (var i = 0; i < n && i < 512; i++) {
      final p = off + 2 + i * 12;
      if (p + 12 > b.length) {
        break;
      }
      out[_u16(p)] = _Entry(_u16(p + 2), _u32(p + 4), _u32(p + 8), p + 8);
    }
    return out;
  }

  String? _ascii(_Entry? x) {
    if (x == null || x.type != 2 || x.count == 0 || x.count > 1024) {
      return null;
    }
    final start = x.count <= 4 ? x.inlineAt : base + x.value;
    if (start < 0 || start + x.count > b.length) {
      return null;
    }
    final s = latin1.decode(b.sublist(start, start + x.count)).replaceAll('\u0000', '').trim();
    return s.isEmpty ? null : s;
  }

  /// Three RATIONALs (degrees, minutes, seconds) plus the N/S/E/W reference.
  double? _coord(_Entry? x, String? ref) {
    if (x == null || x.type != 5 || x.count != 3) {
      return null;
    }
    final start = base + x.value;
    if (start + 24 > b.length) {
      return null;
    }
    double r(int i) {
      final d = _u32(start + i * 8 + 4);
      return d == 0 ? 0 : _u32(start + i * 8) / d;
    }

    final v = r(0) + r(1) / 60 + r(2) / 3600;
    return (ref == 'S' || ref == 'W') ? -v : v;
  }

  static String? _dayOf(String? exifDate) {
    final m = RegExp(r'^(\d{4})[:\-](\d{2})[:\-](\d{2})').firstMatch(exifDate ?? '');
    if (m == null || m.group(1) == '0000') {
      return null;
    }
    return '${m.group(1)}-${m.group(2)}-${m.group(3)}';
  }
}

class _Entry {
  final int type;
  final int count;
  final int value;
  final int inlineAt;
  const _Entry(this.type, this.count, this.value, this.inlineAt);
}
