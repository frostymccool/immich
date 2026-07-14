import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';
import 'package:immich_mobile/services/copyparty/copyparty_logger.dart';

/// Implements the copyparty up2k upload protocol.
///
/// Three-step flow per file:
///   1. Hash file into chunks (SHA-512 per chunk + whole-file hash)
///   2. Handshake POST — tell server about the file, receive needed chunk list
///   3. Upload needed chunks in parallel, then re-handshake to confirm
class CopypartyUploaderService {
  http.Client _client;
  final CopypartyLogger? _log;
  final bool _acceptSelfSignedCert;
  // False when the caller injected their own client (e.g. tests) — we don't
  // know how to rebuild an opaque client we didn't create, so resetConnection
  // is a no-op in that case.
  final bool _ownsClient;

  CopypartyUploaderService({http.Client? client, CopypartyLogger? logger, bool acceptSelfSignedCert = true})
    : _client = client ?? _createClient(acceptSelfSignedCert),
      _log = logger,
      _acceptSelfSignedCert = acceptSelfSignedCert,
      _ownsClient = client == null;

  // Build an HTTP client, optionally accepting self-signed certs (common for
  // home servers).
  static http.Client _createClient(bool acceptSelfSignedCert) {
    if (!acceptSelfSignedCert) {
      return http.Client();
    }
    final inner = HttpClient()..badCertificateCallback = (cert, host, port) => true;
    return IOClient(inner);
  }

  /// Closes the current connection pool and opens a fresh one. A dart:io
  /// HttpClient can keep trying to reuse sockets/routes bound to a network
  /// path that no longer exists (e.g. after connecting a VPN, a wifi handoff,
  /// or a cellular/wifi switch) rather than establishing a new connection —
  /// observed as every request failing with the same "connection abort"/
  /// "no route to host" even once a working route exists again. Safe to call
  /// anytime; in-flight requests on the old client are unaffected (they keep
  /// running against the closed client's still-open sockets until they finish
  /// or themselves fail — closing a Client doesn't cancel in-flight sends).
  void resetConnection() {
    if (!_ownsClient) {
      return;
    }
    final old = _client;
    _client = _createClient(_acceptSelfSignedCert);
    try {
      old.close();
    } catch (_) {}
  }

  void dispose() => _client.close();

  // ---------------------------------------------------------------------------
  // Connection test
  // ---------------------------------------------------------------------------

  /// Returns null on success, or an error string on failure.
  Future<String?> testConnection(String hostUrl, String password) async {
    try {
      final base = hostUrl.replaceAll(RegExp(r'/+$'), '');
      if (base.isEmpty) {
        return 'Host URL is not configured';
      }
      final uri = Uri.parse(base);
      final headers = password.isNotEmpty ? {'X-Password': password} : <String, String>{};
      final response = await _client.get(uri, headers: headers).timeout(const Duration(seconds: 10));
      if (response.statusCode < 400) {
        return null;
      }
      return 'Server returned HTTP ${response.statusCode}';
    } on SocketException catch (e) {
      return 'Cannot reach server: ${e.message}';
    } on TimeoutException {
      return 'Connection timed out after 10 s';
    } catch (e) {
      return 'Error: $e';
    }
  }

  // ---------------------------------------------------------------------------
  // Chunk size — MUST match copyparty's server-side up2k_chunksize() EXACTLY.
  //
  // The server computes each chunk's write offset as (chunk_index * chunksize)
  // using ITS OWN chunk size derived from the file size. If our chunk size
  // differs, the server scatters our chunks across the wrong offsets — the file
  // is corrupt/inflated and no chunk ever matches at the offset the server
  // checks, so confirmation never completes. (A previous 256 KiB table broke
  // this: a 6.3 MB file uploaded as 25 chunks landed at 1 MiB offsets → a
  // ~25 MiB corrupt file. Proven from server folder snapshots.)
  //
  // Port of copyparty/util.py up2k_chunksize: start at 1 MiB and grow (by an
  // accelerating step) until the chunk count is ≤ 256 (or ≤ 4096 once chunks
  // reach 32 MiB).
  // ---------------------------------------------------------------------------

  /// Returns the chunk size in bytes for a given file size.
  int computeChunkSizeBytes(int fileSizeBytes) {
    int chunkSize = 1024 * 1024; // 1 MiB minimum
    int stepSize = 512 * 1024;
    while (true) {
      for (final mul in const [1, 2]) {
        final nchunks = fileSizeBytes <= 0 ? 0 : (fileSizeBytes + chunkSize - 1) ~/ chunkSize; // ceil
        if (nchunks <= 256 || (chunkSize >= 32 * 1024 * 1024 && nchunks <= 4096)) {
          return chunkSize;
        }
        chunkSize += stepSize;
        stepSize *= mul;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Hashing
  // ---------------------------------------------------------------------------

  /// Hashes a file into chunks (SHA-512) and also computes the whole-file hash.
  ///
  /// Reads the file sequentially in chunks of [computeChunkSizeBytes] size.
  /// The whole-file hash is computed over all bytes in order.
  Future<HashedFile> hashFile(
    String filePath, {
    void Function(int bytesProcessed, int totalBytes)? onProgress,
    Completer<void>? cancelToken,
  }) async {
    final file = File(filePath);
    final fileSize = await file.length();
    final chunkSize = computeChunkSizeBytes(fileSize);
    final chunkHashes = <String>[];

    final fileSink = _DigestSink();
    final fileHasher = sha512.startChunkedConversion(fileSink);

    final handle = await file.open(mode: FileMode.read);
    try {
      int bytesRead = 0;
      while (bytesRead < fileSize) {
        // Cancellation must interrupt hashing too — on a large file this loop
        // runs for many seconds and used to ignore the cancel token entirely.
        if (cancelToken?.isCompleted ?? false) {
          throw const CopypartyCancelledException();
        }
        final chunkExpected = (fileSize - bytesRead).clamp(0, chunkSize);

        // Accumulate into a full chunk — read() may return fewer bytes than
        // requested (especially on FAT32/exFAT USB drives via SAF).
        final chunkBuf = BytesBuilder(copy: false);
        while (chunkBuf.length < chunkExpected) {
          final toRead = chunkExpected - chunkBuf.length;
          final slice = await handle.read(toRead);
          if (slice.isEmpty) {
            break;
          }
          chunkBuf.add(slice);
          fileHasher.add(slice);
        }

        final chunkBytes = chunkBuf.takeBytes();
        if (chunkBytes.isEmpty) {
          break;
        }

        chunkHashes.add(_chunkId(chunkBytes));
        bytesRead += chunkBytes.length;
        onProgress?.call(bytesRead, fileSize);
      }
    } finally {
      // close() itself throws on a dead mount (USB unplugged mid-read) — never
      // let that replace the real error or escape the finally.
      try {
        await handle.close();
      } catch (_) {}
    }

    fileHasher.close();
    final fileHash = fileSink.value!.toString();

    final stat = await file.stat();
    final lastModifiedMs = stat.modified.millisecondsSinceEpoch;

    _log?.log(
      'hashed: ${filePath.split('/').last}  size=$fileSize  '
      'chunkSize=$chunkSize  chunks=${chunkHashes.length}',
    );
    if (chunkHashes.isNotEmpty) {
      _log?.log('    first cid: ${chunkHashes.first}');
      if (chunkHashes.length > 1) {
        _log?.log('    last  cid: ${chunkHashes.last}');
      }
    }

    return HashedFile(
      path: filePath,
      filename: filePath.split('/').last,
      totalBytes: fileSize,
      chunkSizeBytes: chunkSize,
      chunkHashes: chunkHashes,
      fileHash: fileHash,
      lastModifiedMs: lastModifiedMs,
    );
  }

  // ---------------------------------------------------------------------------
  // Handshake (step 1 and step 3)
  // ---------------------------------------------------------------------------

  /// Sends the up2k handshake POST.
  ///
  /// Used both initially (step 1) and to confirm after uploading (step 3).
  /// Returns the wark and list of chunk indices the server still needs.
  Future<HandshakeResult> handshake(
    HashedFile file,
    String hostUrl,
    String uploadPath,
    String password, {
    String label = 'handshake',
    Completer<void>? cancelToken,
  }) async {
    final uri = _buildUri(hostUrl, uploadPath, password);
    return _handshakeAtUri(file, uri, hostUrl, password, label: label, cancelToken: cancelToken);
  }

  Future<HandshakeResult> _handshakeAtUri(
    HashedFile file,
    Uri uri,
    String hostUrl,
    String password, {
    String label = 'handshake',
    Completer<void>? cancelToken,
  }) async {
    // lmod must be INTEGER seconds (floor(mtime/1000)) — both the browser
    // (up2k.js) and python (u2c.py) clients send an int; our earlier fractional
    // float (….01) was a divergence and is the prime suspect for the server
    // spinning up a fresh partial on every handshake. We do NOT send `life`
    // (the browser omits it when no lifetime is set; JS drops the undefined key).
    final bodyMap = {
      'name': file.filename,
      'size': file.totalBytes,
      'lmod': file.lastModifiedMs ~/ 1000,
      'hash': file.chunkHashes,
    };
    final body = jsonEncode(bodyMap);

    _log?.request('POST', uri, const {
      'Content-Type': 'application/json',
    }, body: jsonEncode({...bodyMap, 'hash': '[${file.chunkHashes.length} cids]'}));

    // A bad-wifi handshake POST can hang forever (it had no timeout, unlike the
    // chunk upload — the prime suspect for an upload "stuck at 0%" that only a
    // Stop+Resume cleared). Bound it with a stall timeout AND race it against the
    // cancel token so Stop is immediate. Mirrors _uploadChunk.
    final postFuture = _client
        .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(
          const Duration(seconds: 60),
          onTimeout: () => throw CopypartyUploadException('$label stalled (no response in 60s)'),
        );
    final http.Response response;
    if (cancelToken != null) {
      final winner = await Future.any<http.Response?>([
        postFuture,
        cancelToken.future.then<http.Response?>((_) => null),
      ]);
      if (winner == null) {
        // Cancelled mid-handshake: swallow the eventual response so it doesn't
        // surface as an unhandled error, then bail.
        unawaited(postFuture.then<void>((_) {}, onError: (_) {}));
        throw const CopypartyCancelledException();
      }
      response = winner;
    } else {
      response = await postFuture;
    }

    _log?.response(response.statusCode, headers: response.headers, body: response.body);

    if (response.statusCode == 422) {
      // copyparty: a stale/incomplete partial for this file already exists at a
      // different location and it refuses a fresh handshake over it. Re-POSTing
      // the handshake to that partial's file URL just yields 400 "some file got
      // your folder name", so don't — surface an honest, actionable error.
      final resumePath = _parsePurlFrom422(response.body);
      _log?.log('422 → stale partial exists${resumePath != null ? ' at $resumePath' : ''}');
      throw CopypartyUploadException(
        'A stale/incomplete upload for "${file.filename}" already exists on the '
        'server${resumePath != null ? ' at $resumePath' : ''}. copyparty will not '
        'accept a fresh upload over it. Remove that partial on the server, or '
        'point the upload path at an empty folder, then retry.',
      );
    }

    if (response.statusCode != 200) {
      throw CopypartyUploadException('Handshake failed: HTTP ${response.statusCode}\n${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final wark = json['wark'] as String;
    final purl = json['purl'] as String? ?? '';

    // Server returns needed chunk HASHES (not indices) in the 'hash' field.
    // Convert to indices by matching against the file's chunk hash list.
    //
    // CRITICAL: a server-needed hash that does NOT match any of our chunk
    // hashes must be surfaced loudly, not silently dropped. Dropping it makes
    // `need` look empty → false "confirmed". We track unmatched hashes so the
    // caller refuses to confirm and the log shows the mismatch.
    final neededHashes = (json['hash'] as List<dynamic>?)?.cast<String>() ?? <String>[];
    final need = <int>[];
    final unmatched = <String>[];
    for (final h in neededHashes) {
      final idx = file.chunkHashes.indexOf(h);
      if (idx >= 0) {
        need.add(idx);
      } else {
        unmatched.add(h);
      }
    }

    _log?.log(
      '$label parsed: wark=$wark  purl=$purl  '
      'needed=${need.length}/${file.chunkHashes.length}  '
      'unmatched=${unmatched.length}',
    );
    if (unmatched.isNotEmpty) {
      _log?.log('    !! server needs hashes we did not compute:');
      for (final h in unmatched.take(8)) {
        _log?.log('       $h');
      }
    }

    return HandshakeResult(wark: wark, neededChunks: need, purl: purl, unmatchedHashes: unmatched);
  }

  /// Extracts the resume path from a 422 response body.
  ///
  /// Body format (copyparty):
  ///   <pre>partial upload exists at a different location; please resume uploading here instead:
  ///   /uploads/filename-lmod-wark.ext
  ///   URL: uploads
  ///   </pre>
  static String? _parsePurlFrom422(String body) {
    const marker = 'please resume uploading here instead:\n';
    final markerIdx = body.indexOf(marker);
    if (markerIdx < 0) {
      return null;
    }
    final start = markerIdx + marker.length;
    final end = body.indexOf('\n', start);
    final path = (end >= 0 ? body.substring(start, end) : body.substring(start)).trim();
    return path.isEmpty ? null : path;
  }

  // ---------------------------------------------------------------------------
  // Server-side verification (for the cleanup screen)
  // ---------------------------------------------------------------------------

  /// Lists a copyparty folder via the `?ls` JSON API, returning name → size.
  ///
  /// [folderUri] must point at the folder (path ending in `/`).
  Future<Map<String, int>> listFolderSizes(Uri folderUri, String password) async {
    final params = <String, String>{'ls': ''};
    if (password.isNotEmpty) {
      params['pw'] = password;
    }
    final uri = folderUri.replace(queryParameters: params);

    _log?.request('GET', uri, const {'Accept': 'application/json'});
    final resp = await _client.get(uri, headers: {'Accept': 'application/json'});
    _log?.response(
      resp.statusCode,
      headers: resp.headers,
      body: resp.body.length > 600 ? '${resp.body.substring(0, 600)}…' : resp.body,
    );

    if (resp.statusCode == 404) {
      // The folder doesn't exist yet — e.g. an FB9 mirrored subfolder that
      // copyparty only creates on the first upload. That's "no files here",
      // NOT a connection failure. Return an empty listing.
      _log?.log('  folder not found (404) → treating as empty');
      return const <String, int>{};
    }
    if (resp.statusCode != 200) {
      throw CopypartyUploadException('Listing failed: HTTP ${resp.statusCode}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final files = (json['files'] as List<dynamic>?) ?? const [];
    final result = <String, int>{};
    for (final f in files) {
      if (f is Map<String, dynamic>) {
        final href = f['href'] as String?;
        if (href == null) {
          continue;
        }
        final name = Uri.decodeComponent(href.replaceAll(RegExp(r'/+$'), ''));
        final sz = f['sz'];
        result[name] = sz is int ? sz : int.tryParse('$sz') ?? -1;
      }
    }
    return result;
  }

  /// Lists the configured upload folder once (name → size). Used by the import
  /// picker to verify many files against the server with a single request.
  Future<Map<String, int>> listUploadFolder(String hostUrl, String uploadPath, String password) =>
      listFolderSizes(_buildUri(hostUrl, uploadPath, ''), password);

  /// Builds a name/size/partial verification for [filename] from an already
  /// fetched folder listing (no network). Hash axis stays unchecked.
  static ServerFileVerification verificationFromListing(
    Map<String, int> sizes,
    String filename,
    int expectedSize, {
    bool immichApplicable = false,
  }) {
    final serverSize = sizes[filename];
    final sizeOk = serverSize != null && serverSize == expectedSize;
    final partial = _hasPartialFor(sizes.keys, filename);
    // The NAME is on the server if a (complete or 0-byte placeholder) entry
    // exists OR a partial exists — a partial proves the name was created. The
    // size/no-partial chips convey completeness. (Feedback #1)
    final nameFound = sizes.containsKey(filename) || partial;
    return ServerFileVerification(
      filenamePresent: nameFound ? VerifyState.yes : VerifyState.no,
      sizeMatches: serverSize == null ? VerifyState.unknown : (sizeOk ? VerifyState.yes : VerifyState.no),
      partialExists: partial ? VerifyState.yes : VerifyState.no,
      immichApplicable: immichApplicable,
    );
  }

  /// True if the listing contains a `.PARTIAL` that belongs to THIS file —
  /// matched precisely so one filename being a prefix of another can't cross-
  /// attribute partials. Covers `<name>.PARTIAL`, dotpart `.<name>.PARTIAL`,
  /// and copyparty's suffixed `<name>-<time>-<token>.<ext>.PARTIAL`.
  static bool _hasPartialFor(Iterable<String> names, String filename) {
    return names.any(
      (n) =>
          n == '$filename.PARTIAL' ||
          n == '.$filename.PARTIAL' ||
          (n.startsWith('$filename-') && n.endsWith('.PARTIAL')),
    );
  }

  /// Cheap presence check (states 1-3) for a file via a single folder listing.
  /// Does NOT re-hash — that is the separate [verifyHash] step.
  Future<ServerFileVerification> verifyPresence({
    required String fileUrl,
    required String filename,
    required int expectedSize,
    required String password,
  }) async {
    try {
      final fileUri = Uri.parse(fileUrl);
      final segs = List<String>.from(fileUri.pathSegments);
      if (segs.isNotEmpty) {
        segs.removeLast();
      }
      final folderUri = fileUri.replace(pathSegments: [...segs, ''], query: '');

      final sizes = await listFolderSizes(folderUri, password);

      // An in-progress copyparty upload appears as a 0-byte placeholder named
      // exactly <filename> PLUS a "<filename>.PARTIAL" (the sparse data file).
      // So a 0-byte file is NOT "present" — it's an incomplete upload. (Issue 9)
      final serverSize = sizes[filename];
      final sizeOk = serverSize != null && serverSize == expectedSize;
      final partial = _hasPartialFor(sizes.keys, filename);
      final nameFound = sizes.containsKey(filename) || partial;

      return ServerFileVerification(
        filenamePresent: nameFound ? VerifyState.yes : VerifyState.no,
        sizeMatches: serverSize == null ? VerifyState.unknown : (sizeOk ? VerifyState.yes : VerifyState.no),
        partialExists: partial ? VerifyState.yes : VerifyState.no,
      );
    } catch (e) {
      return ServerFileVerification(error: e.toString());
    }
  }

  /// Deep hash validation (state 4): re-hash the local file and run an up2k
  /// handshake. If the server needs zero chunks, the content is fully present
  /// and the hash is validated (timestamped now). Builds on a [base] presence
  /// result so the cheap states are preserved.
  Future<ServerFileVerification> verifyHash({
    required String fileUrl,
    required String localPath,
    required String password,
    ServerFileVerification base = const ServerFileVerification(),
    DateTime? now,
    void Function(int bytesHashed, int totalBytes)? onHashProgress,
  }) async {
    try {
      final fileUri = Uri.parse(fileUrl);
      final origin = '${fileUri.scheme}://${fileUri.authority}';
      final segs = List<String>.from(fileUri.pathSegments)..removeLast();
      final uploadPath = '/${segs.join('/')}';

      final hashed = await hashFile(localPath, onProgress: onHashProgress);
      final hs = await handshake(hashed, origin, uploadPath, password, label: 'verify');
      if (hs.fullyConfirmed) {
        return base.copyWith(
          filenamePresent: VerifyState.yes,
          sizeMatches: VerifyState.yes,
          partialExists: VerifyState.no,
          hashValidatedAt: now ?? DateTime.now(),
        );
      }
      // Server still needs chunks → the upload is incomplete/different content.
      // Clear any prior fresh-hash stamp: this re-verify just FAILED, so the
      // file must drop out of "safe to delete" rather than coast on a stale ✓.
      return base.copyWith(partialExists: VerifyState.yes, clearHash: true);
    } on CopypartyUploadException catch (e) {
      // 422 stale-partial path throws here — that IS a partial.
      return base.copyWith(partialExists: VerifyState.yes, error: e.message, clearHash: true);
    } catch (e) {
      // Network/offline: we could not re-prove the hash, so drop the stale ✓.
      return base.copyWith(error: e.toString(), clearHash: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Chunk upload (step 2)
  // ---------------------------------------------------------------------------

  /// Uploads a single chunk to the server.
  Future<void> _uploadChunk(
    Uri chunkUri,
    String wark,
    String chunkHash,
    Uint8List chunkBytes,
    int chunkIdx, {
    Completer<void>? cancelToken,
  }) async {
    // X-Up2k-Stat is optional progress telemetry (u2c.py only sends it "if
    // stats"); omit it rather than risk a malformed value confusing the server.
    final headers = {'Content-Type': 'application/octet-stream', 'X-Up2k-Wark': wark, 'X-Up2k-Hash': chunkHash};
    // One compact line rather than the general request()/response() dump (a
    // separate log() call per header): this runs on every chunk, at up to
    // `parallelism` concurrency, so the per-line print()/file-write overhead of
    // the full multi-line form adds up fast on large uploads. The wark/headers
    // don't vary per chunk (already logged once at handshake) so nothing
    // diagnostically useful is lost. Failures still get their own full log
    // line below/in the retry loop regardless of this. (jank fix)
    _log?.log('>>> chunk #$chunkIdx (${chunkBytes.length}B) hash=$chunkHash');

    final request = http.Request('POST', chunkUri);
    request.headers.addAll(headers);
    request.bodyBytes = chunkBytes;

    // A stuck socket (bad hotel/airport wifi) can hang a chunk POST forever.
    // Bound it with a stall timeout AND let the user cancel mid-flight: race
    // the send against the cancel token so "Cancel" takes effect immediately
    // instead of waiting for the timeout.
    final sendFuture = _client
        .send(request)
        .timeout(
          const Duration(seconds: 120),
          onTimeout: () => throw const CopypartyUploadException('Chunk upload stalled (no response in 120s)'),
        );
    final http.StreamedResponse response;
    if (cancelToken != null) {
      final winner = await Future.any<http.StreamedResponse?>([
        sendFuture,
        cancelToken.future.then<http.StreamedResponse?>((_) => null),
      ]);
      if (winner == null) {
        // Cancelled: drain/ignore the in-flight response when it arrives so it
        // doesn't surface as an unhandled error, then bail.
        unawaited(sendFuture.then((r) => r.stream.drain<void>().catchError((_) {})).catchError((_) {}));
        throw const CopypartyCancelledException();
      }
      response = winner;
    } else {
      response = await sendFuture;
    }
    final statusCode = response.statusCode;
    final respBody = await response.stream.bytesToString();
    // Compact form (see the matching request log above) — response headers
    // for a chunk POST carry nothing beyond what the handshake already logged.
    _log?.log(
      '<<< chunk #$chunkIdx HTTP $statusCode  body: ${respBody.length > 200 ? respBody.substring(0, 200) : respBody}',
    );

    if (statusCode < 400) {
      return; // 200/204 = accepted.
    }

    // A 400 is only benign when copyparty says the chunk is ALREADY present
    // (a resume/retry race). Any other 400 (e.g. "some file got your folder
    // name") is a real failure and must NOT be swallowed — swallowing it just
    // resurfaces later as a confusing "still needs N chunks" at confirmation.
    final lower = respBody.toLowerCase();
    final alreadyHave = statusCode == 400 && (lower.contains('already') || lower.contains('got that'));
    if (alreadyHave) {
      _log?.log('    chunk #$chunkIdx → 400 already-present (benign)');
      return;
    }

    throw CopypartyUploadException(
      'Chunk #$chunkIdx upload failed: HTTP $statusCode '
      '(wark=$wark, hash=$chunkHash)\n$respBody',
    );
  }

  /// Uploads the required chunks in parallel (up to [parallelism] at once).
  ///
  /// [purl] is the partial-upload URL returned by the handshake; chunks are
  /// POSTed there (matching the u2c.py reference client behaviour).
  Future<void> uploadChunks(
    HashedFile file,
    String wark,
    List<int> neededChunkIndices,
    String hostUrl,
    String purl,
    String password, {
    int parallelism = 2,
    // BYTES done/total across just the NEEDED chunks (not the whole file —
    // uploadHashedFile adds the already-confirmed baseline before forwarding
    // to its own caller). Byte-based rather than chunk-count-based so the
    // last (possibly shorter) chunk doesn't skew the fraction.
    void Function(int bytesDone, int bytesTotal)? onProgress,
    Completer<void>? cancelToken,
  }) async {
    if (neededChunkIndices.isEmpty) {
      return;
    }

    int chunkByteLength(int idx) {
      final start = idx * file.chunkSizeBytes;
      final end = (start + file.chunkSizeBytes).clamp(0, file.totalBytes);
      return end - start;
    }

    final neededBytesTotal = neededChunkIndices.fold<int>(0, (s, idx) => s + chunkByteLength(idx));

    final chunkUri = _buildChunkUri(hostUrl, purl, password);
    _log?.log(
      'uploading ${neededChunkIndices.length} chunk(s) to $chunkUri '
      '(parallelism=$parallelism)',
    );

    // Cap concurrency by a MEMORY budget, not just the configured count. Each
    // in-flight chunk is held ~twice (read buffer + the http bodyBytes copy),
    // and chunk size grows with file size (up to ~32 MiB for multi-GB files), so
    // `parallelism × 2 × chunkSize` can hit ~256 MiB and get the app OOM-killed
    // on a large import. Bound the concurrent chunk bytes to ~128 MiB. (crash A1)
    const memBudgetBytes = 128 * 1024 * 1024;
    final memCap = (memBudgetBytes ~/ (2 * file.chunkSizeBytes)).clamp(1, parallelism);
    final effParallelism = memCap < parallelism ? memCap : parallelism;
    if (effParallelism != parallelism) {
      _log?.log(
        '    capping parallelism $parallelism → $effParallelism (chunk ${file.chunkSizeBytes ~/ (1024 * 1024)} MiB, mem budget)',
      );
    }

    int bytesDone = 0;
    final semaphore = _Semaphore(effParallelism);

    final futures = neededChunkIndices.map((chunkIdx) async {
      await semaphore.acquire();
      try {
        if (cancelToken?.isCompleted ?? false) {
          throw const CopypartyCancelledException();
        }
        final start = chunkIdx * file.chunkSizeBytes;
        final end = (start + file.chunkSizeBytes).clamp(0, file.totalBytes);
        final chunkBytes = await _readChunk(file.path, start, end - start);
        // Retry transient chunk failures (stall timeout, dropped socket, 5xx)
        // with a short backoff before failing the whole file — the reference
        // u2c.py client retries chunks rather than aborting. A user cancel is
        // never retried. (batch3 item 9)
        const maxAttempts = 3;
        for (var attempt = 1; ; attempt++) {
          try {
            await _uploadChunk(
              chunkUri,
              wark,
              file.chunkHashes[chunkIdx],
              chunkBytes,
              chunkIdx,
              cancelToken: cancelToken,
            );
            break;
          } on CopypartyCancelledException {
            rethrow;
          } catch (e) {
            if (attempt >= maxAttempts || (cancelToken?.isCompleted ?? false)) {
              rethrow;
            }
            _log?.log('    chunk #$chunkIdx attempt $attempt failed ($e) — retrying in ${2 * attempt}s');
            await Future<void>.delayed(Duration(seconds: 2 * attempt));
            if (cancelToken?.isCompleted ?? false) {
              throw const CopypartyCancelledException();
            }
          }
        }
        bytesDone += end - start;
        onProgress?.call(bytesDone, neededBytesTotal);
      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
  }

  /// Confirm the upload by re-running handshake and checking need is empty.
  ///
  /// Returns true if the server confirms receipt, false if chunks are missing.
  Future<bool> confirmUpload(HashedFile file, String wark, String hostUrl, String uploadPath, String password) async {
    final result = await handshake(file, hostUrl, uploadPath, password);
    return result.fullyConfirmed;
  }

  // ---------------------------------------------------------------------------
  // Self-test: one instrumented, non-throwing upload attempt
  // ---------------------------------------------------------------------------

  /// Runs a full up2k attempt for one file and returns a structured result
  /// instead of throwing. Used by the self-test suite to compare variations
  /// (same name vs renamed vs new content vs new folder) with hard numbers.
  Future<UploadAttemptResult> runInstrumentedUpload({
    required String filePath,
    required String hostUrl,
    required String uploadPath,
    required String password,
    required String label,
    int parallelism = 4,
    bool sequential = false,
  }) async {
    final name = filePath.split('/').last;
    _log?.section('SELFTEST $label');
    _log?.log(
      'name="$name"  uploadPath="$uploadPath"  '
      'mode=${sequential ? 'sequential(in-order, parallelism=1)' : 'parallel($parallelism)'}',
    );

    // Snapshot the destination folder before/after so we can SEE what the
    // server actually does with our chunks (partial created? grows? corrupt
    // file left behind?). Filters to entries related to this file.
    final prefix = name.length > 23 ? name.substring(0, 23) : name;
    Future<void> snapshotFolder(String when) async {
      try {
        final folderUri = _buildUri(hostUrl, uploadPath, '');
        final sizes = await listFolderSizes(folderUri, password);
        final related = sizes.entries.where((e) => e.key.contains(prefix)).toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        _log?.log(
          'FOLDER $when — ${sizes.length} total file(s); '
          '${related.length} matching "$prefix*":',
        );
        if (related.isEmpty) {
          _log?.log('    (none)');
        } else {
          for (final e in related.take(30)) {
            _log?.log('    ${e.value} B  ${e.key}');
          }
        }
      } catch (e) {
        _log?.log('FOLDER $when — listing failed: $e');
      }
    }

    try {
      final hashed = await hashFile(filePath);
      await snapshotFolder('BEFORE');
      final hs = await handshake(hashed, hostUrl, uploadPath, password, label: '$label/init');
      // Sequential mode: upload one chunk at a time, in ascending offset order,
      // to test whether this server mis-places concurrent/out-of-order chunks.
      final needed = sequential ? (List<int>.from(hs.neededChunks)..sort()) : hs.neededChunks;
      final initialNeeded = needed.length;
      await uploadChunks(
        hashed,
        hs.wark,
        needed,
        hostUrl,
        hs.purl,
        password,
        parallelism: sequential ? 1 : parallelism,
      );
      await snapshotFolder('AFTER-UPLOAD (pre-confirm)');
      final confirm = await handshake(hashed, hostUrl, uploadPath, password, label: '$label/confirm');
      await snapshotFolder('AFTER-CONFIRM');
      final result = UploadAttemptResult(
        label: label,
        sentName: name,
        uploadPath: uploadPath,
        wark: hs.wark,
        totalChunks: hashed.chunkHashes.length,
        initialNeeded: initialNeeded,
        uploadedChunks: needed.length,
        finalNeeded: confirm.neededChunks.length,
        success: confirm.fullyConfirmed,
      );
      _log?.log('RESULT ${result.summaryLine}');
      return result;
    } catch (e) {
      final result = UploadAttemptResult(
        label: label,
        sentName: name,
        uploadPath: uploadPath,
        wark: null,
        totalChunks: -1,
        initialNeeded: -1,
        uploadedChunks: 0,
        finalNeeded: -1,
        success: false,
        error: e.toString(),
      );
      _log?.log('RESULT ${result.summaryLine}');
      return result;
    }
  }

  // ---------------------------------------------------------------------------
  // Receipt file writing
  // ---------------------------------------------------------------------------

  /// Writes a .cpreceipt sidecar file alongside the source file.
  ///
  /// Returns true on success, false on failure.
  Future<bool> writeReceiptFile(
    HashedFile file,
    String wark,
    String hostUrl,
    String uploadPath,
    String appVersion,
  ) async {
    try {
      final uploadUrl = '${hostUrl.trimRight()}/${uploadPath.replaceAll(RegExp(r'^/+|/+$'), '')}/${file.filename}';
      final receiptData = {
        'version': 1,
        'filename': file.filename,
        'size_bytes': file.totalBytes,
        'sha512_file': file.fileHash,
        'wark': wark,
        'upload_timestamp_utc': DateTime.now().toUtc().toIso8601String(),
        'copyparty_url': uploadUrl,
        'app_version': appVersion,
      };
      final receiptPath = '${file.path}.cpreceipt';
      await File(receiptPath).writeAsString(const JsonEncoder.withIndent('  ').convert(receiptData));
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Full single-file upload pipeline
  // ---------------------------------------------------------------------------

  /// Runs the complete up2k protocol for a single file.
  ///
  /// Returns the [HandshakeResult] from the final confirmation handshake.
  /// Runs the up2k protocol for one file.
  ///
  /// Returns `(hashed, result, alreadyOnServer)`. When `alreadyOnServer` is
  /// true the content was already fully present (hash matched) and NO bytes
  /// were uploaded — the caller should show "already on server, hash verified".
  Future<(HashedFile, HandshakeResult, bool)> uploadFile(
    String filePath,
    String hostUrl,
    String uploadPath,
    String password, {
    int parallelism = 2,
    void Function(int bytesHashed, int totalBytes)? onHashProgress,
    void Function(int bytesDone, int bytesTotal)? onUploadProgress,
    Completer<void>? cancelToken,
  }) async {
    _log?.section('UPLOAD ${filePath.split('/').last}');
    _log?.log('host=$hostUrl  uploadPath="$uploadPath"  parallelism=$parallelism');

    void throwIfCancelled() {
      if (cancelToken?.isCompleted ?? false) {
        throw const CopypartyCancelledException();
      }
    }

    throwIfCancelled();
    // Step 1: hash (cancellable — hashing a multi-GB file can take a while).
    final hashed = await hashFile(filePath, onProgress: onHashProgress, cancelToken: cancelToken);

    // Steps 2–4: handshake → upload → confirm.
    final (result, alreadyOnServer) = await uploadHashedFile(
      hashed,
      hostUrl,
      uploadPath,
      password,
      parallelism: parallelism,
      onUploadProgress: onUploadProgress,
      cancelToken: cancelToken,
    );
    return (hashed, result, alreadyOnServer);
  }

  /// Runs the up2k protocol for an ALREADY-hashed file (steps 2–4): initial
  /// handshake → chunk upload → confirm. Chunk bytes are read from
  /// [HashedFile.path], so this works whether that points at the original source
  /// or a local staged copy. Returns `(result, alreadyOnServer)`.
  Future<(HandshakeResult, bool)> uploadHashedFile(
    HashedFile hashed,
    String hostUrl,
    String uploadPath,
    String password, {
    int parallelism = 2,
    // BYTES done/total across the WHOLE file (not just the needed chunks) —
    // chunks the server already had (e.g. resuming after a pause/interrupted
    // upload) count as immediately done, so a mostly-complete resume shows
    // close to its true % right away instead of restarting the bar from 0
    // and racing to 100% over just the few remaining chunks.
    void Function(int bytesDone, int bytesTotal)? onUploadProgress,
    Completer<void>? cancelToken,
  }) async {
    void throwIfCancelled() {
      if (cancelToken?.isCompleted ?? false) {
        throw const CopypartyCancelledException();
      }
    }

    throwIfCancelled();
    // Step 2: initial handshake — find out which chunks the server needs.
    // This IS the content hash check: if it comes back fullyConfirmed, the
    // file's bytes are already on the server.
    final handshakeResult = await handshake(hashed, hostUrl, uploadPath, password, cancelToken: cancelToken);

    // If the content is already fully present, STOP. Sending a second
    // (confirm) handshake here would re-register the now-existing name and make
    // copyparty serialise a duplicate `<name>-<time>-<token>` file. (Issue 2.)
    if (handshakeResult.fullyConfirmed) {
      _log?.log(
        '✓ already on server (hash verified, no upload): '
        'wark=${handshakeResult.wark}',
      );
      return (handshakeResult, true);
    }

    int chunkByteLength(int idx) {
      final start = idx * hashed.chunkSizeBytes;
      final end = (start + hashed.chunkSizeBytes).clamp(0, hashed.totalBytes);
      return end - start;
    }

    // Step 3+4: upload the needed chunks, then confirm. If the CONFIRM
    // handshake still reports missing chunks, retry by uploading exactly
    // those and re-confirming, instead of failing the whole file after one
    // round — observed after a pause/resume: the confirm handshake can
    // report chunks the upload pass didn't know about (e.g. a chunk POST
    // that "succeeded" client-side but the server's up2k.snap didn't end up
    // recording, or a resume racing a stale needed-list) as a hard failure
    // even though a second round would fix it with no re-hash needed. A
    // genuine hash MISMATCH is NOT retried — that's a content problem retry
    // can't fix, not a transient one.
    const maxConfirmAttempts = 3;
    var neededChunks = handshakeResult.neededChunks;
    var confirmed = handshakeResult;
    for (var attempt = 1; attempt <= maxConfirmAttempts; attempt++) {
      if (neededChunks.isNotEmpty) {
        final neededBytesTotal = neededChunks.fold<int>(0, (s, idx) => s + chunkByteLength(idx));
        final alreadyConfirmedBytes = hashed.totalBytes - neededBytesTotal;
        // Report the resume baseline immediately, before the first new chunk
        // completes, so a mostly-done resume doesn't sit at 0% for however
        // long the first remaining chunk takes.
        onUploadProgress?.call(alreadyConfirmedBytes, hashed.totalBytes);
        await uploadChunks(
          hashed,
          confirmed.wark,
          neededChunks,
          hostUrl,
          confirmed.purl,
          password,
          parallelism: parallelism,
          onProgress: onUploadProgress == null
              ? null
              : (bytesDoneInNeeded, _) =>
                    onUploadProgress(alreadyConfirmedBytes + bytesDoneInNeeded, hashed.totalBytes),
          cancelToken: cancelToken,
        );
      }

      throwIfCancelled();
      // Confirmation handshake — triggers server finalization (.PARTIAL →
      // file). Also tells us whether anything is STILL missing.
      //
      // The POST itself (not just its response) can hit a transient network
      // error — confirmed in the field: a file whose all 503/503 chunks had
      // already gotten "thank" responses still ended up FAILED because the
      // confirm POST's own socket hit a broken pipe. At that point every byte
      // is already safely on the server; retrying this cheap, idempotent
      // re-check costs nothing, so a raw network exception here gets the same
      // bounded retry as an incomplete-chunk response, instead of failing the
      // whole file over the very last, already-redundant request.
      for (var netAttempt = 1; ; netAttempt++) {
        try {
          confirmed = await handshake(
            hashed,
            hostUrl,
            uploadPath,
            password,
            label: 'confirm',
            cancelToken: cancelToken,
          );
          break;
        } on CopypartyCancelledException {
          rethrow;
        } catch (e) {
          if (netAttempt >= maxConfirmAttempts) {
            rethrow;
          }
          _log?.log('confirm POST attempt $netAttempt/$maxConfirmAttempts failed ($e) — retrying in 2s');
          await Future<void>.delayed(const Duration(seconds: 2));
          throwIfCancelled();
        }
      }
      if (confirmed.fullyConfirmed) {
        _log?.log('✓ confirmed: wark=${confirmed.wark}');
        return (confirmed, false);
      }
      if (confirmed.unmatchedHashes.isNotEmpty || confirmed.neededChunks.isEmpty) {
        // Unmatched-hash mismatch: not retryable. Empty neededChunks despite
        // !fullyConfirmed shouldn't happen, but don't loop forever on it either.
        break;
      }
      _log?.log(
        'confirm attempt $attempt/$maxConfirmAttempts: server still needs '
        '${confirmed.neededChunks.length} chunk(s) — retrying',
      );
      neededChunks = confirmed.neededChunks;
    }
    final detail = confirmed.unmatchedHashes.isNotEmpty
        ? 'server needs ${confirmed.unmatchedHashes.length} chunk(s) whose '
              'hashes do not match what we computed — likely a hashing or '
              'partial-file mismatch (see diagnostic log)'
        : 'server still needs ${confirmed.neededChunks.length} chunk(s) after $maxConfirmAttempts attempt(s)';
    _log?.log('!! CONFIRM FAILED: $detail');
    throw CopypartyUploadException('Upload confirmation failed: $detail');
  }

  /// Copies [sourcePath] → [stagedPath] while computing the up2k chunk hashes
  /// and whole-file hash in the SAME single read pass (so the slow source volume
  /// is read only once). The returned [HashedFile] has `path == stagedPath`, so
  /// the subsequent upload reads from the fast local copy.
  ///
  /// Corruption safety: after writing, the staged file's length is verified to
  /// equal the source length before the [HashedFile] is returned; a mismatch
  /// throws. The caller is responsible for writing the completion marker only
  /// after this returns successfully, and for deleting a partial [stagedPath] on
  /// any throw. Uses the exact same chunk sizing + cid computation as
  /// [hashFile], so the protocol invariant can never diverge between the two.
  Future<HashedFile> stageAndHash(
    String sourcePath,
    String stagedPath, {
    // `verifying` is true while re-hashing an already-on-disk partial to
    // resume it (fast, local-only, no new bytes) and false during an actual
    // USB copy — callers need this to label the two honestly, since both
    // otherwise look identical (numerator climbing from 0), and a "verifying"
    // pass was mistaken for the copy restarting from scratch.
    void Function(int bytesProcessed, int totalBytes, bool verifying)? onProgress,
    Completer<void>? cancelToken,
  }) async {
    final source = File(sourcePath);
    final fileSize = await source.length();
    final chunkSize = computeChunkSizeBytes(fileSize);
    final chunkHashes = <String>[];

    final fileSink = _DigestSink();
    final fileHasher = sha512.startChunkedConversion(fileSink);

    final dest = File(stagedPath);
    await dest.parent.create(recursive: true);

    // Resume from a partial copy left by a previous paused/skipped attempt
    // instead of always re-reading the whole (slow, USB) source from byte 0.
    // Only whole already-written CHUNKS are trusted, replayed from the fast
    // LOCAL partial (never the USB source) through the same hasher the main
    // loop below continues using — replaying identical bytes through SHA-512
    // is deterministic, so the resulting running state is indistinguishable
    // from having hashed them in one continuous pass. Any doubt at all falls
    // back to wiping and starting clean, exactly like before this existed.
    int resumeOffset = 0;
    if (await dest.exists()) {
      try {
        final existingLen = await dest.length();
        final candidateOffset = (existingLen ~/ chunkSize) * chunkSize;
        if (candidateOffset > 0 && candidateOffset <= fileSize) {
          final replayHandle = await dest.open(mode: FileMode.read);
          try {
            int replayed = 0;
            while (replayed < candidateOffset) {
              // The replay itself never checked for cancellation — a pause
              // request had to wait for the ENTIRE partial to finish replaying
              // (minutes, for a large one) before it took effect, even though
              // the yield above kept the UI/heartbeat alive throughout. Confirmed
              // in the field: pause requested 32s into a 6880MiB/215-chunk
              // replay, but CANCELLED didn't land until the replay's own log
              // line ~5.5 minutes later.
              if (cancelToken?.isCompleted ?? false) {
                throw const CopypartyCancelledException();
              }
              final chunkExpected = (candidateOffset - replayed).clamp(0, chunkSize);
              final chunkBuf = BytesBuilder(copy: false);
              while (chunkBuf.length < chunkExpected) {
                final slice = await replayHandle.read(chunkExpected - chunkBuf.length);
                if (slice.isEmpty) {
                  break;
                }
                chunkBuf.add(slice);
              }
              final chunkBytes = chunkBuf.takeBytes();
              if (chunkBytes.length != chunkExpected) {
                break; // short read — don't trust the partial, fall through to wipe.
              }
              fileHasher.add(chunkBytes);
              chunkHashes.add(_chunkId(chunkBytes));
              replayed += chunkBytes.length;
              // Report replay progress too — otherwise the progress bar sits
              // frozen at whatever it showed before the pause for as long as
              // the replay takes (minutes, for a multi-GiB partial), which
              // reads as a hang even though the app is actually responsive.
              onProgress?.call(replayed, fileSize, true);
              // Yield after every chunk — each chunk's SHA-512 pass is
              // synchronous CPU work (up to 32 MiB) and a large partial can
              // have hundreds of them; without this the isolate never returns
              // to the event loop, starving UI frames and the heartbeat timer
              // for tens of seconds (confirmed via a missing heartbeat tick
              // spanning a 6880MiB/215-chunk replay in the field).
              await Future<void>.delayed(Duration.zero);
            }
            if (replayed == candidateOffset) {
              resumeOffset = candidateOffset;
              _log?.log(
                'staging: resuming ${sourcePath.split('/').last} from '
                '${(resumeOffset / (1024 * 1024)).round()}MiB '
                '(${chunkHashes.length} chunk(s) already copied)',
              );
            }
          } finally {
            await replayHandle.close();
          }
        }
      } on CopypartyCancelledException {
        // A genuine pause mid-replay, not an untrustworthy partial — the
        // replay only READS dest to re-verify it, never writes, so nothing on
        // disk needs wiping. Propagate so the caller sees the cancellation
        // instead of this falling through to "resumeOffset == 0 → wipe".
        rethrow;
      } catch (_) {}
      if (resumeOffset == 0) {
        chunkHashes.clear();
        try {
          await dest.delete();
        } catch (_) {}
      }
    }

    final readHandle = await source.open(mode: FileMode.read);
    if (resumeOffset > 0) {
      await readHandle.setPosition(resumeOffset);
    }
    // Append when resuming (the partial's already-written bytes must survive);
    // truncate when starting clean (a stale partial must not leave trailing
    // bytes past what we write now).
    final writeHandle = await dest.open(mode: resumeOffset > 0 ? FileMode.writeOnlyAppend : FileMode.writeOnly);
    var ok = false;
    var cancelledCleanly = false;
    // Measure where the copy wall-clock actually goes: USB read vs hashing vs
    // local write. These run in series per chunk, so the sum ≈ total copy time,
    // and the split tells us whether hashing is throttling the USB drain (→ worth
    // decoupling to a pure copy) or the USB read itself is the floor. (feedback)
    final readSw = Stopwatch();
    final hashSw = Stopwatch();
    final writeSw = Stopwatch();
    try {
      int bytesRead = resumeOffset;
      // Force a real fsync periodically so a multi-GB copy doesn't leave GBs of
      // dirty pages sitting in RAM waiting for the single flush at the end — on a
      // big import that dirty-page backlog adds to system memory pressure (the
      // crash also killed the VPN = system-wide OOM). (crash mitigation)
      int sinceFlush = 0;
      const flushEvery = 64 * 1024 * 1024;
      while (bytesRead < fileSize) {
        if (cancelToken?.isCompleted ?? false) {
          throw const CopypartyCancelledException();
        }
        final chunkExpected = (fileSize - bytesRead).clamp(0, chunkSize);
        final chunkBuf = BytesBuilder(copy: false);
        while (chunkBuf.length < chunkExpected) {
          final toRead = chunkExpected - chunkBuf.length;
          readSw.start();
          final slice = await readHandle.read(toRead);
          readSw.stop();
          if (slice.isEmpty) {
            break;
          }
          chunkBuf.add(slice);
          hashSw.start();
          fileHasher.add(slice);
          hashSw.stop();
        }
        final chunkBytes = chunkBuf.takeBytes();
        if (chunkBytes.isEmpty) {
          break;
        }
        writeSw.start();
        await writeHandle.writeFrom(chunkBytes);
        sinceFlush += chunkBytes.length;
        if (sinceFlush >= flushEvery) {
          await writeHandle.flush();
          sinceFlush = 0;
        }
        writeSw.stop();
        hashSw.start();
        chunkHashes.add(_chunkId(chunkBytes));
        hashSw.stop();
        bytesRead += chunkBytes.length;
        onProgress?.call(bytesRead, fileSize, false);
      }
      await writeHandle.flush();
      ok = true;
    } on CopypartyCancelledException {
      // Clean user cancel (pause/skip) — KEEP the partial (flushed up through
      // the last COMPLETE chunk above) so a future resume can replay it
      // instead of re-reading everything from the USB source again.
      try {
        await writeHandle.flush();
      } catch (_) {}
      cancelledCleanly = true;
      rethrow;
    } finally {
      // A dead mount (USB unplugged mid-copy) makes readHandle.close() itself
      // throw — guard both closes so the write handle still closes and the
      // partial-file cleanup below still runs.
      try {
        await readHandle.close();
      } catch (_) {}
      try {
        await writeHandle.close();
      } catch (_) {}
      if (!ok && !cancelledCleanly) {
        // A genuine failure (IO error, out of space, dead mount) — never
        // trust a partial that didn't end at a clean, deliberate cancel.
        try {
          await dest.delete();
        } catch (_) {}
      }
    }

    // Corruption guard: the staged copy MUST be byte-for-byte complete.
    final stagedLen = await dest.length();
    if (stagedLen != fileSize) {
      try {
        await dest.delete();
      } catch (_) {}
      throw CopypartyUploadException(
        'Staging copy incomplete for ${sourcePath.split('/').last}: '
        'wrote $stagedLen of $fileSize bytes',
      );
    }

    fileHasher.close();
    final fileHash = fileSink.value!.toString();
    final stat = await source.stat();

    String mbps(int bytes, int ms) => ms <= 0 ? '∞' : (bytes / (ms / 1000) / (1024 * 1024)).toStringAsFixed(1);
    final rd = readSw.elapsedMilliseconds;
    final hs = hashSw.elapsedMilliseconds;
    final wr = writeSw.elapsedMilliseconds;
    _log?.log(
      'staged: ${sourcePath.split('/').last}  size=$fileSize  '
      'chunks=${chunkHashes.length}  → ${stagedPath.split('/').last}\n'
      '    usbRead ${mbps(fileSize, rd)} MB/s (${rd}ms) · '
      'hash ${mbps(fileSize, hs)} MB/s (${hs}ms) · '
      'write ${mbps(fileSize, wr)} MB/s (${wr}ms) · total ${rd + hs + wr}ms',
    );

    return HashedFile(
      path: stagedPath,
      filename: sourcePath.split('/').last,
      totalBytes: fileSize,
      chunkSizeBytes: chunkSize,
      chunkHashes: chunkHashes,
      fileHash: fileHash,
      lastModifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Copyparty chunk ID: SHA-512 of chunk bytes, first 33 bytes, URL-safe base64.
  /// Matches the cid format used by copyparty's up2k protocol.
  static String _chunkId(List<int> bytes) {
    final digest = sha512.convert(bytes);
    final truncated = Uint8List.fromList(digest.bytes.sublist(0, 33));
    return base64Url.encode(truncated);
  }

  Uri _buildUri(String hostUrl, String uploadPath, String password) {
    final base = hostUrl.replaceAll(RegExp(r'/+$'), '');
    final cleanPath = uploadPath.replaceAll(RegExp(r'^/+|/+$'), '');
    final baseUri = Uri.parse(base);
    // Build the path from discrete segments so each is percent-encoded — a
    // mirrored folder name can contain spaces or other reserved characters
    // (FB9, e.g. "Camera 01"). A trailing empty segment yields the "/" suffix.
    final segments = [
      ...baseUri.pathSegments.where((s) => s.isNotEmpty),
      ...cleanPath.split('/').where((s) => s.isNotEmpty),
      '',
    ];
    var uri = baseUri.replace(pathSegments: segments);
    if (password.isNotEmpty) {
      uri = uri.replace(queryParameters: {'pw': password});
    }
    return uri;
  }

  /// Builds the chunk upload URI from the server-provided [purl].
  ///
  /// [purl] may be an absolute URL or a path relative to the host.
  /// The password query param is appended when present.
  Uri _buildChunkUri(String hostUrl, String purl, String password) {
    final Uri base;
    if (purl.startsWith('http://') || purl.startsWith('https://')) {
      base = Uri.parse(purl);
    } else if (purl.isNotEmpty) {
      final host = Uri.parse(hostUrl.trimRight());
      base = host.replace(path: purl);
    } else {
      // Fallback: use the same base URL as the handshake
      return _buildUri(hostUrl, '', password).replace(path: Uri.parse(hostUrl.trimRight()).path);
    }
    if (password.isEmpty) {
      return base;
    }
    final params = Map<String, String>.from(base.queryParameters);
    if (!params.containsKey('pw')) {
      params['pw'] = password;
    }
    return base.replace(queryParameters: params);
  }

  Future<Uint8List> _readChunk(String filePath, int start, int length) async {
    final file = File(filePath);
    final handle = await file.open(mode: FileMode.read);
    try {
      await handle.setPosition(start);
      final buf = BytesBuilder(copy: false);
      while (buf.length < length) {
        final slice = await handle.read(length - buf.length);
        if (slice.isEmpty) {
          break;
        }
        buf.add(slice);
      }
      return buf.takeBytes();
    } finally {
      try {
        await handle.close();
      } catch (_) {}
    }
  }
}

/// Simple semaphore for bounding parallelism.
class _Semaphore {
  final int _max;
  int _current = 0;
  final List<Completer<void>> _queue = [];

  _Semaphore(this._max);

  Future<void> acquire() async {
    if (_current < _max) {
      _current++;
      return;
    }
    final completer = Completer<void>();
    _queue.add(completer);
    await completer.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      next.complete();
    } else {
      _current--;
    }
  }
}

/// Sink that captures the final Digest from a chunked SHA-512 computation.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

class CopypartyUploadException implements Exception {
  final String message;
  const CopypartyUploadException(this.message);

  @override
  String toString() => 'CopypartyUploadException: $message';
}

/// Thrown when an upload is cancelled by the user (via the cancel token).
/// Distinct from [CopypartyUploadException] so callers can treat a deliberate
/// cancel differently from a real failure.
class CopypartyCancelledException implements Exception {
  final String message;
  const CopypartyCancelledException([this.message = 'Upload cancelled']);

  @override
  String toString() => 'CopypartyCancelledException: $message';
}
