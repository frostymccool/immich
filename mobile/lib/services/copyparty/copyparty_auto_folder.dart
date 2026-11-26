import 'dart:async';

import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/services/copyparty/copyparty_camera_info.dart';

/// What the planner knows about one capture set.
class SetFacts {
  final String setId;

  /// `YYYY-MM-DD`, the shooting day.
  final String day;
  final CameraFileInfo info;

  const SetFacts({required this.setId, required this.day, required this.info});
}

/// The proposed destination folder (one level under the upload path) for every set.
class AutoFolderPlan {
  final Map<String, String> folderBySet;

  /// How each place was found, for the log: day → 'photo GPS' / 'phone location' / 'none'.
  final Map<String, String> placeSource;

  /// Ready-made names the user can pick instead of typing, per PROPOSED folder name: the same day and camera
  /// with each other place name found (city, nearest place, county, state…) and without a place.
  final Map<String, List<String>> alternatives;

  const AutoFolderPlan(this.folderBySet, [this.placeSource = const {}, this.alternatives = const {}]);

  /// The distinct folder names, in first-seen order, with their set counts.
  Map<String, int> get folders {
    final out = <String, int>{};
    for (final f in folderBySet.values) {
      out[f] = (out[f] ?? 0) + 1;
    }
    return out;
  }

  /// The same plan with folders renamed by the user ([renames]: proposed name → chosen name).
  AutoFolderPlan renamed(Map<String, String> renames) => AutoFolderPlan(
    {for (final e in folderBySet.entries) e.key: sanitizeFolderName(renames[e.value] ?? e.value)},
    placeSource,
    alternatives,
  );
}

/// `Insta360 X4` → `X4`, `Insta360 Luna Ultra` → `GO Ultra`, `GoPro HERO9 Black` → `HERO9 Black`, other makers'
/// models as they are.
String? shortCameraName(String? model) {
  if (model == null) {
    return null;
  }
  var m = model.replaceAll(RegExp(r'\s+'), ' ').trim();
  m = m.replaceFirst(RegExp(r'^(insta360|arashi vision|gopro)\s+', caseSensitive: false), '').trim();
  // Insta360 writes some models under their internal code name: the GO Ultra's files say "Luna Ultra".
  m = _codeNames[m.toLowerCase()] ?? m;
  m = sanitizeFolderName(m);
  return m.isEmpty ? null : m;
}

const _codeNames = {'luna ultra': 'GO Ultra'};

/// A folder name copyparty and every OS accept: no slashes or reserved characters, no leading dot,
/// single spaces, at most 100 characters.
String sanitizeFolderName(String name) {
  var s = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceFirst(RegExp(r'^\.+'), '').trim();
  if (s.length > 100) {
    s = s.substring(0, 100).trim();
  }
  return s;
}

const _fold = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', //
  'ç': 'c', 'č': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', //
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i', 'ñ': 'n', 'ń': 'n', //
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o', //
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u', 'ý': 'y', 'ÿ': 'y', //
  'š': 's', 'ś': 's', 'ž': 'z', 'ź': 'z', 'ż': 'z', 'ł': 'l', 'ß': 'ss',
};

/// A place name as a folder word: Latin accents dropped (`Málaga` → `Malaga`), other scripts kept.
String placeForFolder(String place) {
  final out = StringBuffer();
  for (final ch in place.split('')) {
    final lower = ch.toLowerCase();
    final f = _fold[lower];
    if (f == null) {
      out.write(ch);
    } else {
      out.write(ch == lower ? f : (f.substring(0, 1).toUpperCase() + f.substring(1)));
    }
  }
  return sanitizeFolderName(out.toString());
}

/// Builds `<Place> <YYYY-MM-DD> <Camera>` for each set. Pure: no I/O.
///
/// Camera: the set's own model; a set with none takes the most common camera of the import, else `Camera`.
/// Two cameras of the same model (different serials) get the serial's last 4 characters appended.
/// Place: [placeByDay] for the set's day; left out when unknown.
AutoFolderPlan planFolders(List<SetFacts> sets, Map<String, String?> placeByDay) {
  final label = <String, String?>{for (final s in sets) s.setId: shortCameraName(s.info.model)};
  final counts = <String, int>{};
  for (final l in label.values.whereType<String>()) {
    counts[l] = (counts[l] ?? 0) + 1;
  }
  String? common;
  for (final e in counts.entries) {
    if (common == null || e.value > counts[common]!) {
      common = e.key;
    }
  }
  final serials = <String, Set<String>>{};
  for (final s in sets) {
    final l = label[s.setId];
    final serial = s.info.serial;
    if (l != null && serial != null && serial.isNotEmpty) {
      serials.putIfAbsent(l, () => {}).add(serial);
    }
  }
  final out = <String, String>{};
  for (final s in sets) {
    var camera = label[s.setId] ?? common ?? 'Camera';
    final serial = s.info.serial;
    if (label[s.setId] != null && (serials[camera]?.length ?? 0) > 1 && serial != null && serial.isNotEmpty) {
      camera = '$camera ${serial.length <= 4 ? serial : serial.substring(serial.length - 4)}';
    }
    final place = placeByDay[s.day];
    final parts = [if (place != null && place.isNotEmpty) place, s.day, camera];
    out[s.setId] = sanitizeFolderName(parts.join(' '));
  }
  return AutoFolderPlan(out);
}

/// Reads the sets' files and resolves places, then plans. Every outside call is injected (testable) and
/// bounded by a timeout, so the import is never held up for long by a slow card, network or GPS.
class AutoFolderService {
  final Future<CameraFileInfo> Function(String path) readInfo;

  /// Coordinates → place names, best first (for example the city, the nearest place, the county, the state).
  /// The first is used; the others are offered as alternatives.
  final Future<List<String>> Function(double lat, double lon) placeNames;

  /// At most this many place names are offered per day.
  static const maxPlaceOptions = 4;

  /// The phone's current position, or null (no permission, no fix).
  final Future<(double, double)?> Function() phoneLocation;
  final DateTime Function() now;
  final void Function(String)? log;

  /// The phone's location is used only for days at most this far back: older days were shot elsewhere.
  static const phoneLocationMaxAge = Duration(days: 3);
  static const lookupTimeout = Duration(seconds: 8);

  /// Longer: the first import may show Android's location permission question.
  static const phoneTimeout = Duration(seconds: 30);

  AutoFolderService({
    required this.readInfo,
    required this.placeNames,
    required this.phoneLocation,
    DateTime Function()? now,
    this.log,
  }) : now = now ?? DateTime.now;

  /// Files read per set, best first: photos (EXIF), then the main video; never the .lrv preview.
  static List<UploadFile> _candidates(UploadSet set) {
    int rank(UploadFile f) {
      if (CameraInfoReader.isPhoto(f.localPath)) {
        return 0;
      }
      if (CameraInfoReader.isVideo(f.localPath)) {
        return 1;
      }
      return 9;
    }

    final files = set.files.where((f) => rank(f) < 9).toList()..sort((a, b) => rank(a).compareTo(rank(b)));
    return files.take(3).toList();
  }

  static String _dayOfMs(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<CameraFileInfo> _readSet(UploadSet set) async {
    var info = CameraFileInfo.empty;
    for (final f in _candidates(set)) {
      try {
        info = info.merge(await readInfo(f.localPath).timeout(lookupTimeout));
      } catch (_) {}
      if (info.model != null && info.day != null) {
        break;
      }
    }
    if (info.day == null) {
      // No date in the files or names: the name's date of any file, else the oldest modification time.
      for (final f in set.files) {
        final d = CameraInfoReader.dayFromFilename(f.filename);
        if (d != null) {
          return info.merge(CameraFileInfo(day: d));
        }
      }
      final oldest = set.files.map((f) => f.lastModifiedMs).fold<int?>(null, (a, b) => a == null || b < a ? b : a);
      if (oldest != null) {
        info = info.merge(CameraFileInfo(day: _dayOfMs(oldest)));
      }
    }
    return info;
  }

  Future<AutoFolderPlan> plan(List<UploadSet> sets) async {
    final facts = <SetFacts>[];
    for (final set in sets) {
      final info = await _readSet(set);
      facts.add(SetFacts(setId: set.id, day: info.day ?? _dayOfMs(now().millisecondsSinceEpoch), info: info));
    }

    final optionsByDay = <String, List<String>>{};
    final source = <String, String>{};
    final cache = <String, List<String>>{};
    Future<List<String>> geocode(double lat, double lon) async {
      final key = '${lat.toStringAsFixed(2)},${lon.toStringAsFixed(2)}';
      final cached = cache[key];
      if (cached != null) {
        return cached;
      }
      var names = const <String>[];
      try {
        names = await placeNames(lat, lon).timeout(lookupTimeout);
      } catch (e) {
        log?.call('auto folders: place lookup failed ($e)');
      }
      final out = <String>[];
      for (final n in names) {
        final p = placeForFolder(n);
        if (p.isNotEmpty && !out.any((o) => o.toLowerCase() == p.toLowerCase())) {
          out.add(p);
        }
      }
      return cache[key] = out.take(maxPlaceOptions).toList();
    }

    final days = facts.map((f) => f.day).toSet();
    final needPhone = <String>[];
    for (final day in days) {
      final gps = facts.where((f) => f.day == day && f.info.hasGps).map((f) => f.info).firstOrNull;
      if (gps != null) {
        optionsByDay[day] = await geocode(gps.lat!, gps.lon!);
        source[day] = optionsByDay[day]!.isEmpty ? 'photo GPS, no place name' : 'photo GPS';
      } else {
        needPhone.add(day);
      }
    }
    final today = now();
    final recent = needPhone.where((day) {
      final d = DateTime.tryParse(day);
      return d != null && today.difference(d) <= phoneLocationMaxAge + const Duration(days: 1);
    }).toList();
    if (recent.isNotEmpty) {
      (double, double)? here;
      try {
        here = await phoneLocation().timeout(phoneTimeout);
      } catch (e) {
        log?.call('auto folders: phone location unavailable ($e)');
      }
      final places = here == null ? const <String>[] : await geocode(here.$1, here.$2);
      for (final day in recent) {
        optionsByDay[day] = places;
        source[day] = places.isEmpty ? 'phone location unavailable' : 'phone location';
      }
    }
    for (final day in needPhone.where((d) => !recent.contains(d))) {
      source[day] = 'no GPS, too old for the phone location';
    }

    final plan = planFolders(facts, {for (final e in optionsByDay.entries) e.key: e.value.firstOrNull});
    // Alternatives: the same "<day> <camera>" with each place name, and without a place.
    final noPlace = planFolders(facts, const {});
    final alternatives = <String, List<String>>{};
    for (final f in facts) {
      final proposed = plan.folderBySet[f.setId]!;
      final base = noPlace.folderBySet[f.setId]!;
      final list = alternatives.putIfAbsent(proposed, () => [proposed]);
      for (final name in [
        for (final place in optionsByDay[f.day] ?? const <String>[]) sanitizeFolderName('$place $base'),
        base,
      ]) {
        if (!list.contains(name)) {
          list.add(name);
        }
      }
      log?.call(
        'auto folder: set ${f.setId.substring(0, 8)} model=${f.info.model ?? '-'} day=${f.day} '
        'place=${source[f.day] ?? '-'} -> "$proposed"',
      );
    }
    for (final e in alternatives.entries) {
      log?.call('auto folder: "${e.key}" alternatives: ${e.value.skip(1).map((n) => '"$n"').join(', ')}');
    }
    return AutoFolderPlan(plan.folderBySet, source, alternatives);
  }
}

/// `/uploads` + `Lisbon 2026-05-02 X4` → `/uploads/Lisbon 2026-05-02 X4`.
String autoFolderUploadPath(String base, String folder) => '${base.replaceAll(RegExp(r'/+$'), '')}/$folder';
