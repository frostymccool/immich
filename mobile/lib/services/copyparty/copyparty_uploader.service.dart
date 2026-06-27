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
  final http.Client _client;
  final CopypartyLogger? _log;

  CopypartyUploaderService({http.Client? client, CopypartyLogger? logger})
      : _client = client ?? _createClient(),
        _log = logger;

  // Build an HTTP client that accepts self-signed certs (common for home servers).
  static http.Client _createClient() {
    final inner = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    return IOClient(inner);
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
      final response = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 10));
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
  // Chunk size table — mirrors the up2k reference table from copyparty devnotes
  // ---------------------------------------------------------------------------

  static const List<(int maxBytes, int chunkBytes)> _chunkTable = [
    (256 * 1024 * 1024, 256 * 1024),                    // ≤ 256 MiB → 256 KiB chunks
    (512 * 1024 * 1024, 512 * 1024),                    // ≤ 512 MiB → 512 KiB chunks
    (1 * 1024 * 1024 * 1024, 1 * 1024 * 1024),          // ≤ 1 GiB → 1 MiB chunks
    (2 * 1024 * 1024 * 1024, 2 * 1024 * 1024),          // ≤ 2 GiB → 2 MiB chunks
    (4 * 1024 * 1024 * 1024, 4 * 1024 * 1024),          // ≤ 4 GiB → 4 MiB chunks
    (8 * 1024 * 1024 * 1024, 8 * 1024 * 1024),          // ≤ 8 GiB → 8 MiB chunks
    (128 * 1024 * 1024 * 1024, 16 * 1024 * 1024),       // ≤ 128 GiB → 16 MiB chunks
  ];

  /// Returns the chunk size in bytes for a given file size.
  int computeChunkSizeBytes(int fileSizeBytes) {
    for (final (maxBytes, chunkBytes) in _chunkTable) {
      if (fileSizeBytes <= maxBytes) {
        return chunkBytes;
      }
    }
    return 32 * 1024 * 1024; // 32 MiB for anything larger
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
        final chunkExpected = (fileSize - bytesRead).clamp(0, chunkSize);

        // Accumulate into a full chunk — read() may return fewer bytes than
        // requested (especially on FAT32/exFAT USB drives via SAF).
        final chunkBuf = BytesBuilder(copy: false);
        while (chunkBuf.length < chunkExpected) {
          final toRead = chunkExpected - chunkBuf.length;
          final slice = await handle.read(toRead);
          if (slice.isEmpty) break;
          chunkBuf.add(slice);
          fileHasher.add(slice);
        }

        final chunkBytes = chunkBuf.takeBytes();
        if (chunkBytes.isEmpty) break;

        chunkHashes.add(_chunkId(chunkBytes));
        bytesRead += chunkBytes.length;
        onProgress?.call(bytesRead, fileSize);
      }
    } finally {
      await handle.close();
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
  }) async {
    final uri = _buildUri(hostUrl, uploadPath, password);
    return _handshakeAtUri(file, uri, hostUrl, password, label: label);
  }

  Future<HandshakeResult> _handshakeAtUri(
    HashedFile file,
    Uri uri,
    String hostUrl,
    String password, {
    String label = 'handshake',
  }) async {
    final bodyMap = {
      'name': file.filename,
      'size': file.totalBytes,
      'lmod': file.lastModifiedMs / 1000.0,
      'hash': file.chunkHashes,
    };
    final body = jsonEncode(bodyMap);

    _log?.request('POST', uri, const {'Content-Type': 'application/json'},
        body: jsonEncode({...bodyMap, 'hash': '[${file.chunkHashes.length} cids]'}));

    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

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
      throw CopypartyUploadException(
        'Handshake failed: HTTP ${response.statusCode}\n${response.body}',
      );
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

    return HandshakeResult(
      wark: wark,
      neededChunks: need,
      purl: purl,
      unmatchedHashes: unmatched,
    );
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
    if (markerIdx < 0) return null;
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
    if (password.isNotEmpty) params['pw'] = password;
    final uri = folderUri.replace(queryParameters: params);

    _log?.request('GET', uri, const {'Accept': 'application/json'});
    final resp = await _client.get(uri, headers: {'Accept': 'application/json'});
    _log?.response(resp.statusCode,
        headers: resp.headers,
        body: resp.body.length > 600 ? '${resp.body.substring(0, 600)}…' : resp.body);

    if (resp.statusCode != 200) {
      throw CopypartyUploadException('Listing failed: HTTP ${resp.statusCode}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final files = (json['files'] as List<dynamic>?) ?? const [];
    final result = <String, int>{};
    for (final f in files) {
      if (f is Map<String, dynamic>) {
        final href = f['href'] as String?;
        if (href == null) continue;
        final name = Uri.decodeComponent(href.replaceAll(RegExp(r'/+$'), ''));
        final sz = f['sz'];
        result[name] = sz is int ? sz : int.tryParse('$sz') ?? -1;
      }
    }
    return result;
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
      if (segs.isNotEmpty) segs.removeLast();
      final folderUri = fileUri.replace(pathSegments: [...segs, ''], query: '');

      final sizes = await listFolderSizes(folderUri, password);
      final present = sizes.containsKey(filename);
      final sizeOk = present && sizes[filename] == expectedSize;
      // copyparty partials are named "<filename>-<time>-<token>.<ext>" (we saw
      // this in the logs) or, older style, "<filename>.PARTIAL".
      final partial = sizes.keys.any((n) => n != filename && n.startsWith(filename));

      return ServerFileVerification(
        filenamePresent: present ? VerifyState.yes : VerifyState.no,
        sizeMatches: !present
            ? VerifyState.unknown
            : (sizeOk ? VerifyState.yes : VerifyState.no),
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
  }) async {
    try {
      final fileUri = Uri.parse(fileUrl);
      final origin = '${fileUri.scheme}://${fileUri.authority}';
      final segs = List<String>.from(fileUri.pathSegments)..removeLast();
      final uploadPath = '/${segs.join('/')}';

      final hashed = await hashFile(localPath);
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
      return base.copyWith(partialExists: VerifyState.yes);
    } on CopypartyUploadException catch (e) {
      // 422 stale-partial path throws here — that IS a partial.
      return base.copyWith(partialExists: VerifyState.yes, error: e.message);
    } catch (e) {
      return base.copyWith(error: e.toString());
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
    int chunkIdx,
  ) async {
    final headers = {
      'Content-Type': 'application/octet-stream',
      'X-Up2k-Wark': wark,
      'X-Up2k-Hash': chunkHash,
    };
    _log?.request('POST', chunkUri, headers,
        body: 'chunk #$chunkIdx (${chunkBytes.length} bytes)');

    final request = http.Request('POST', chunkUri);
    request.headers.addAll(headers);
    request.bodyBytes = chunkBytes;

    final response = await _client.send(request);
    final statusCode = response.statusCode;
    final respBody = await response.stream.bytesToString();
    _log?.response(statusCode, headers: response.headers, body: respBody);

    if (statusCode < 400) return; // 200/204 = accepted.

    // A 400 is only benign when copyparty says the chunk is ALREADY present
    // (a resume/retry race). Any other 400 (e.g. "some file got your folder
    // name") is a real failure and must NOT be swallowed — swallowing it just
    // resurfaces later as a confusing "still needs N chunks" at confirmation.
    final lower = respBody.toLowerCase();
    final alreadyHave = statusCode == 400 &&
        (lower.contains('already') || lower.contains('got that'));
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
    void Function(int chunksDone, int chunksTotal)? onProgress,
  }) async {
    if (neededChunkIndices.isEmpty) {
      return;
    }

    final chunkUri = _buildChunkUri(hostUrl, purl, password);
    _log?.log(
      'uploading ${neededChunkIndices.length} chunk(s) to $chunkUri '
      '(parallelism=$parallelism)',
    );

    int done = 0;
    final semaphore = _Semaphore(parallelism);

    final futures = neededChunkIndices.map((chunkIdx) async {
      await semaphore.acquire();
      try {
        final start = chunkIdx * file.chunkSizeBytes;
        final end = (start + file.chunkSizeBytes).clamp(0, file.totalBytes);
        final chunkBytes = await _readChunk(file.path, start, end - start);
        await _uploadChunk(
          chunkUri,
          wark,
          file.chunkHashes[chunkIdx],
          chunkBytes,
          chunkIdx,
        );
        done++;
        onProgress?.call(done, neededChunkIndices.length);
      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
  }

  /// Confirm the upload by re-running handshake and checking need is empty.
  ///
  /// Returns true if the server confirms receipt, false if chunks are missing.
  Future<bool> confirmUpload(
    HashedFile file,
    String wark,
    String hostUrl,
    String uploadPath,
    String password,
  ) async {
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
    _log?.log('name="$name"  uploadPath="$uploadPath"  '
        'mode=${sequential ? 'sequential(in-order, parallelism=1)' : 'parallel($parallelism)'}');
    try {
      final hashed = await hashFile(filePath);
      final hs = await handshake(hashed, hostUrl, uploadPath, password, label: '$label/init');
      // Sequential mode: upload one chunk at a time, in ascending offset order,
      // to test whether this server mis-places concurrent/out-of-order chunks.
      final needed =
          sequential ? (List<int>.from(hs.neededChunks)..sort()) : hs.neededChunks;
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
      final confirm =
          await handshake(hashed, hostUrl, uploadPath, password, label: '$label/confirm');
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
      final uploadUrl =
          '${hostUrl.trimRight()}/${uploadPath.replaceAll(RegExp(r'^/+|/+$'), '')}/${file.filename}';
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
      await File(receiptPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(receiptData),
      );
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
  Future<(HashedFile, HandshakeResult)> uploadFile(
    String filePath,
    String hostUrl,
    String uploadPath,
    String password, {
    int parallelism = 2,
    void Function(int bytesHashed, int totalBytes)? onHashProgress,
    void Function(int chunksDone, int chunksTotal)? onUploadProgress,
  }) async {
    _log?.section('UPLOAD ${filePath.split('/').last}');
    _log?.log('host=$hostUrl  uploadPath="$uploadPath"  parallelism=$parallelism');

    // Step 1: hash
    final hashed = await hashFile(filePath, onProgress: onHashProgress);

    // Step 2: initial handshake — find out which chunks the server needs.
    // Even if need==[] (server has all chunks from a prior attempt), we MUST
    // still send the confirmation handshake (step 4) to trigger server-side
    // finalization.  Skipping it leaves the file as .PARTIAL indefinitely.
    final handshakeResult =
        await handshake(hashed, hostUrl, uploadPath, password);

    // Step 3: upload any missing chunks (no-op when neededChunks is empty).
    // Use purl from handshake response as the chunk upload endpoint — this
    // matches what the u2c.py reference client does.
    await uploadChunks(
      hashed,
      handshakeResult.wark,
      handshakeResult.neededChunks,
      hostUrl,
      handshakeResult.purl,
      password,
      parallelism: parallelism,
      onProgress: onUploadProgress,
    );

    // Step 4: confirmation handshake — triggers server finalization (.PARTIAL → file).
    final confirmed =
        await handshake(hashed, hostUrl, uploadPath, password, label: 'confirm');
    if (!confirmed.fullyConfirmed) {
      final detail = confirmed.unmatchedHashes.isNotEmpty
          ? 'server needs ${confirmed.unmatchedHashes.length} chunk(s) whose '
              'hashes do not match what we computed — likely a hashing or '
              'partial-file mismatch (see diagnostic log)'
          : 'server still needs ${confirmed.neededChunks.length} chunk(s)';
      _log?.log('!! CONFIRM FAILED: $detail');
      throw CopypartyUploadException('Upload confirmation failed: $detail');
    }
    _log?.log('✓ confirmed: wark=${confirmed.wark}');
    return (hashed, confirmed);
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
    // Empty path → post to the server root ("$base/"), not "$base//".
    final target = cleanPath.isEmpty ? '$base/' : '$base/$cleanPath/';
    final uri = Uri.parse(target).replace(
      queryParameters: password.isNotEmpty ? {'pw': password} : null,
    );
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
      return _buildUri(hostUrl, '', password)
          .replace(path: Uri.parse(hostUrl.trimRight()).path);
    }
    if (password.isEmpty) return base;
    final params = Map<String, String>.from(base.queryParameters);
    if (!params.containsKey('pw')) params['pw'] = password;
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
        if (slice.isEmpty) break;
        buf.add(slice);
      }
      return buf.takeBytes();
    } finally {
      await handle.close();
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
