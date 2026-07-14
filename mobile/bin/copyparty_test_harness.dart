// ignore_for_file: avoid_print
//
// Scripted copyparty up2k protocol test harness.
//
// Runs the SAME production code (CopypartyUploaderService) the app uses,
// directly against a real copyparty server, from the command line — no
// phone, no USB card, no manual repro required. Built so failure scenarios
// found in the field (resume races, broken-pipe-on-confirm, etc.) can be
// reproduced and re-checked on demand instead of waiting for them to happen
// again organically.
//
// Requires its OWN credential (see: Settings → Copyparty Import →
// Diagnostics → "Test harness password", debug mode). That password lives
// in the app's secure storage (Android Keystore), which this standalone
// process cannot read — pass it explicitly via --password or the
// COPYPARTY_TEST_PASSWORD env var. Use a DELETE-CAPABLE login pointed at an
// isolated test subfolder — never the real upload path — since scenarios
// upload real (synthetic) files and clean up by deleting them afterward.
//
// Usage (from the mobile/ directory):
//   dart run bin/copyparty_test_harness.dart \
//     --host https://192.168.5.21:3923 \
//     --path /uploads/_test_harness \
//     --password <delete-capable password> \
//     --scenario all --size-mb 64 --repeat 3
//
// Scenarios:
//   basic        upload a synthetic file once, confirm, delete.
//   resume       upload, interrupt partway (simulated cancel), resume with a
//                fresh call, confirm the server-driven resume completes.
//   broken-pipe  inject a simulated network failure on the Nth JSON POST
//                (default: the 2nd — the confirm handshake, matching the
//                exact build-115 field bug) and confirm the retry logic
//                still completes the upload instead of failing it.
//   all          runs all three in sequence.
//
// Run `dart run bin/copyparty_test_harness.dart --help` for all flags.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/services/copyparty/copyparty_uploader.service.dart';

Future<void> main(List<String> args) async {
  final opts = _Options.parse(args);
  if (opts == null) {
    exit(64); // EX_USAGE
  }

  print('=== copyparty test harness ===');
  print('host:            ${opts.host}');
  print('path:            ${opts.path}');
  print('scenario:        ${opts.scenario}');
  print('size:            ${opts.sizeMb} MiB');
  print('repeat:          ${opts.repeat}');
  print('cleanup:         ${!opts.keep}');
  print('accept-self-signed: ${opts.selfSigned}');
  if (opts.scenario == 'broken-pipe' || opts.scenario == 'all') {
    print('fail-nth-json-post: ${opts.failOnNthJsonPost}');
  }
  print('');

  var passed = 0;
  var failed = 0;
  for (var i = 1; i <= opts.repeat; i++) {
    print('--- run $i/${opts.repeat} ---');
    try {
      switch (opts.scenario) {
        case 'basic':
          await _scenarioBasic(opts, i);
        case 'resume':
          await _scenarioResume(opts, i);
        case 'broken-pipe':
          await _scenarioBrokenPipe(opts, i);
        case 'all':
          await _scenarioBasic(opts, i);
          await _scenarioResume(opts, i);
          await _scenarioBrokenPipe(opts, i);
      }
      print('✓ run $i PASSED');
      passed++;
    } catch (e, st) {
      print('✗ run $i FAILED: $e');
      if (opts.verbose) {
        print(st);
      }
      failed++;
    }
    print('');
  }

  print('=== summary: $passed passed, $failed failed (of ${opts.repeat}) ===');
  exit(failed == 0 ? 0 : 1);
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

Future<void> _scenarioBasic(_Options o, int run) async {
  final file = await _makeTestFile(o.sizeMb, 'basic_$run');
  final uploader = CopypartyUploaderService(client: _realClient(o.selfSigned), acceptSelfSignedCert: o.selfSigned);
  try {
    print('[basic] hashing ${o.sizeMb} MiB...');
    final hashed = await uploader.hashFile(file.path);
    print('[basic] uploading (${hashed.chunkHashes.length} chunks)...');
    final (result, alreadyOnServer) = await uploader.uploadHashedFile(hashed, o.host, o.path, o.password);
    if (!result.fullyConfirmed) {
      throw 'server did not confirm: needed=${result.neededChunks.length} '
          'unmatched=${result.unmatchedHashes.length}';
    }
    print('[basic] confirmed: wark=${result.wark} alreadyOnServer=$alreadyOnServer');
    await _cleanup(uploader, o, hashed.filename);
  } finally {
    uploader.dispose();
    await file.parent.delete(recursive: true);
  }
}

Future<void> _scenarioResume(_Options o, int run) async {
  final file = await _makeTestFile(o.sizeMb, 'resume_$run');
  final uploader = CopypartyUploaderService(client: _realClient(o.selfSigned), acceptSelfSignedCert: o.selfSigned);
  try {
    print('[resume] hashing ${o.sizeMb} MiB...');
    final hashed = await uploader.hashFile(file.path);
    if (hashed.chunkHashes.length < 3) {
      throw 'file too small to interrupt mid-upload (${hashed.chunkHashes.length} chunk(s)) '
          '— try a larger --size-mb';
    }

    print('[resume] uploading, interrupting partway...');
    final cancelToken = Completer<void>();
    var sawProgress = false;
    var interrupted = false;
    try {
      await uploader.uploadHashedFile(
        hashed,
        o.host,
        o.path,
        o.password,
        onUploadProgress: (done, total) {
          sawProgress = true;
          if (done > total * 0.4 && !cancelToken.isCompleted) {
            cancelToken.complete();
          }
        },
        cancelToken: cancelToken,
      );
    } on CopypartyCancelledException {
      interrupted = true;
    }
    if (!interrupted) {
      throw 'expected an interruption but the upload completed in one pass '
          '(file too small/fast to interrupt? try a larger --size-mb)';
    }
    if (!sawProgress) {
      throw 'cancelled before any progress was ever reported';
    }
    print('[resume] interrupted as expected — resuming with a fresh call...');

    final (result, _) = await uploader.uploadHashedFile(hashed, o.host, o.path, o.password);
    if (!result.fullyConfirmed) {
      throw 'resume did not confirm: needed=${result.neededChunks.length} '
          'unmatched=${result.unmatchedHashes.length}';
    }
    print('[resume] resumed + confirmed: wark=${result.wark}');
    await _cleanup(uploader, o, hashed.filename);
  } finally {
    uploader.dispose();
    await file.parent.delete(recursive: true);
  }
}

Future<void> _scenarioBrokenPipe(_Options o, int run) async {
  final file = await _makeTestFile(o.sizeMb, 'brokenpipe_$run');
  final flaky = _FlakyClient(_realClient(o.selfSigned), failOnNthJsonPost: o.failOnNthJsonPost);
  final uploader = CopypartyUploaderService(client: flaky, acceptSelfSignedCert: o.selfSigned);
  try {
    print('[broken-pipe] hashing ${o.sizeMb} MiB...');
    final hashed = await uploader.hashFile(file.path);
    print(
      '[broken-pipe] uploading — JSON POST #${o.failOnNthJsonPost} will simulate '
      'a broken pipe (matches the build-115 field bug: the confirm handshake, '
      'after every chunk already succeeded, hitting a transient socket error)...',
    );
    final (result, _) = await uploader.uploadHashedFile(hashed, o.host, o.path, o.password);
    if (!result.fullyConfirmed) {
      throw 'did not confirm despite the retry logic: needed=${result.neededChunks.length} '
          'unmatched=${result.unmatchedHashes.length}';
    }
    if (flaky.failedCount == 0) {
      throw 'the simulated failure never actually fired — check --fail-nth-json-post '
          'against how many JSON POSTs this run makes';
    }
    print('[broken-pipe] confirmed despite ${flaky.failedCount} simulated failure(s): wark=${result.wark}');
    await _cleanup(uploader, o, hashed.filename);
  } finally {
    uploader.dispose();
    await file.parent.delete(recursive: true);
  }
}

Future<void> _cleanup(CopypartyUploaderService uploader, _Options o, String filename) async {
  if (o.keep) {
    print('  (--keep set, leaving $filename on the server)');
    return;
  }
  try {
    await uploader.deleteFile(o.host, o.path, filename, o.password);
    print('  cleaned up: deleted $filename from the server');
  } catch (e) {
    print(
      '  WARNING: cleanup delete failed for $filename: $e '
      '(needs the delete-capable test password, not the normal upload password)',
    );
  }
}

// ---------------------------------------------------------------------------
// Synthetic test file generation
// ---------------------------------------------------------------------------

Future<File> _makeTestFile(int sizeMb, String label) async {
  final dir = await Directory.systemTemp.createTemp('cp_harness_');
  final file = File('${dir.path}/${label}_${DateTime.now().microsecondsSinceEpoch}.bin');
  final sink = file.openWrite();
  final rnd = Random();
  const blockSize = 4 * 1024 * 1024;
  var remaining = sizeMb * 1024 * 1024;
  var blockIndex = 0;
  try {
    while (remaining > 0) {
      final n = remaining < blockSize ? remaining : blockSize;
      final block = Uint8List(n);
      final words = ByteData.view(block.buffer);
      var i = 0;
      while (i + 4 <= n) {
        words.setUint32(i, rnd.nextInt(1 << 32));
        i += 4;
      }
      while (i < n) {
        block[i] = rnd.nextInt(256);
        i++;
      }
      // Stamp the block index into the first bytes so identical-looking
      // random blocks (unlikely, but possible for small sizes) never collide.
      if (n >= 4) {
        words.setUint32(0, blockIndex);
      }
      sink.add(block);
      remaining -= n;
      blockIndex++;
    }
  } finally {
    await sink.close();
  }
  return file;
}

http.Client _realClient(bool acceptSelfSigned) {
  if (!acceptSelfSigned) {
    return http.Client();
  }
  final inner = HttpClient()..badCertificateCallback = (cert, host, port) => true;
  return IOClient(inner);
}

/// Wraps a real client and throws a simulated broken-pipe on the Nth JSON
/// (handshake-shaped) POST — chunk uploads are octet-stream, so this only
/// ever hits handshake/confirm requests, never a chunk.
class _FlakyClient extends http.BaseClient {
  final http.Client _inner;
  final int failOnNthJsonPost;
  int _jsonPostCount = 0;
  int failedCount = 0;

  _FlakyClient(this._inner, {required this.failOnNthJsonPost});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final isJsonPost = request.method == 'POST' && request.headers['Content-Type'] == 'application/json';
    if (isJsonPost) {
      _jsonPostCount++;
      if (_jsonPostCount == failOnNthJsonPost) {
        failedCount++;
        throw http.ClientException(
          'SocketException: Broken pipe (OS Error: Broken pipe, errno = 32) [simulated by test harness]',
          request.url,
        );
      }
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

// ---------------------------------------------------------------------------
// CLI options
// ---------------------------------------------------------------------------

class _Options {
  final String host;
  final String path;
  final String password;
  final String scenario;
  final int sizeMb;
  final int repeat;
  final bool keep;
  final bool selfSigned;
  final int failOnNthJsonPost;
  final bool verbose;

  _Options({
    required this.host,
    required this.path,
    required this.password,
    required this.scenario,
    required this.sizeMb,
    required this.repeat,
    required this.keep,
    required this.selfSigned,
    required this.failOnNthJsonPost,
    required this.verbose,
  });

  static const _validScenarios = ['basic', 'resume', 'broken-pipe', 'all'];

  static _Options? parse(List<String> args) {
    String? host;
    String? path;
    String? password = Platform.environment['COPYPARTY_TEST_PASSWORD'];
    var scenario = 'all';
    var sizeMb = 64;
    var repeat = 1;
    var keep = false;
    var selfSigned = true;
    var failOnNthJsonPost = 2;
    var verbose = false;

    var i = 0;
    while (i < args.length) {
      final arg = args[i];
      String next() {
        i++;
        if (i >= args.length) {
          throw 'missing value for $arg';
        }
        return args[i];
      }

      switch (arg) {
        case '--help' || '-h':
          _printUsage();
          return null;
        case '--host':
          host = next();
        case '--path':
          path = next();
        case '--password':
          password = next();
        case '--scenario':
          scenario = next();
        case '--size-mb':
          sizeMb = int.parse(next());
        case '--repeat':
          repeat = int.parse(next());
        case '--keep':
          keep = true;
        case '--no-self-signed':
          selfSigned = false;
        case '--fail-nth-json-post':
          failOnNthJsonPost = int.parse(next());
        case '--verbose':
          verbose = true;
        default:
          stderr.writeln('Unknown argument: $arg');
          _printUsage();
          return null;
      }
      i++;
    }

    final missing = <String>[
      if (host == null || host.isEmpty) '--host',
      if (path == null || path.isEmpty) '--path',
      if (password == null || password.isEmpty) '--password (or COPYPARTY_TEST_PASSWORD)',
    ];
    if (missing.isNotEmpty) {
      stderr.writeln('Missing required argument(s): ${missing.join(', ')}');
      _printUsage();
      return null;
    }
    if (!_validScenarios.contains(scenario)) {
      stderr.writeln('Invalid --scenario "$scenario" — must be one of: ${_validScenarios.join(', ')}');
      return null;
    }
    if (sizeMb < 1 || repeat < 1) {
      stderr.writeln('--size-mb and --repeat must be >= 1');
      return null;
    }

    return _Options(
      host: host!,
      path: path!,
      password: password!,
      scenario: scenario,
      sizeMb: sizeMb,
      repeat: repeat,
      keep: keep,
      selfSigned: selfSigned,
      failOnNthJsonPost: failOnNthJsonPost,
      verbose: verbose,
    );
  }

  static void _printUsage() {
    print('''
copyparty up2k protocol test harness — reuses the app's own upload code
directly against a real server, from the command line.

Usage:
  dart run bin/copyparty_test_harness.dart --host <url> --path <path> --password <pw> [options]

Required:
  --host <url>       e.g. https://192.168.5.21:3923
  --path <path>      upload subfolder — use an ISOLATED test folder, e.g. /uploads/_test_harness
  --password <pw>    a DELETE-CAPABLE copyparty login (or set COPYPARTY_TEST_PASSWORD)

Options:
  --scenario <name>  basic | resume | broken-pipe | all   (default: all)
  --size-mb <n>      synthetic test file size in MiB      (default: 64)
  --repeat <n>       run the scenario(s) N times           (default: 1)
  --keep             don't delete test files after a run   (default: cleans up)
  --no-self-signed   reject self-signed certs              (default: accepts them)
  --fail-nth-json-post <n>  which handshake-shaped POST the broken-pipe
                     scenario fails (default: 2 — the confirm handshake)
  --verbose          print stack traces on failure
  --help             this message
''');
  }
}
