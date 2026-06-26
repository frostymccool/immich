import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/copyparty/copyparty_models.dart';

/// Implements the copyparty up2k upload protocol.
///
/// Three-step flow per file:
///   1. Hash file into chunks (SHA-512 per chunk + whole-file hash)
///   2. Handshake POST — tell server about the file, receive needed chunk list
///   3. Upload needed chunks in parallel, then re-handshake to confirm
class CopypartyUploaderService {
  final http.Client _client;

  CopypartyUploaderService({http.Client? client}) : _client = client ?? _createClient();

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
    String password,
  ) async {
    final uri = _buildUri(hostUrl, uploadPath, password);

    final body = jsonEncode({
      'name': file.filename,
      'size': file.totalBytes,
      'lmod': file.lastModifiedMs / 1000.0,
      'hash': file.chunkHashes,
    });

    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

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
    final neededHashes = (json['hash'] as List<dynamic>?)?.cast<String>() ?? <String>[];
    final need = neededHashes
        .map((h) => file.chunkHashes.indexOf(h))
        .where((i) => i >= 0)
        .toList();

    return HandshakeResult(wark: wark, neededChunks: need, purl: purl);
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
  ) async {
    final request = http.Request('POST', chunkUri);
    request.headers['Content-Type'] = 'application/octet-stream';
    request.headers['X-Up2k-Wark'] = wark;
    request.headers['X-Up2k-Hash'] = chunkHash;
    request.bodyBytes = chunkBytes;

    final response = await _client.send(request);
    final statusCode = response.statusCode;
    // 204 = accepted; 200 = accepted with body; 400 can mean "already got that" (chunk
    // was already on server) which is benign — the confirmation handshake verifies.
    if (statusCode >= 400 && statusCode != 400) {
      final body = await response.stream.bytesToString();
      throw CopypartyUploadException(
        'Chunk upload failed: HTTP $statusCode (wark=$wark, hash=$chunkHash)\n$body',
      );
    }
    if (statusCode == 400) {
      await response.stream.drain<void>();
      return; // "already got that" — chunk exists, continue
    }
    await response.stream.drain<void>();
  }

  /// Builds the X-Up2k-Hash header value for a chunk upload.
  ///
  /// We upload one chunk per HTTP request, so only the current chunk's hash
  /// is included. The sibling-hash optimisation in u2c.py is only used when
  /// multiple chunks are batched into a single request body, which we don't do.
  static String _buildChunkHashHeader(int chunkIdx, List<String> allChunkHashes) {
    return allChunkHashes[chunkIdx];
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
    int parallelism = 4,
    void Function(int chunksDone, int chunksTotal)? onProgress,
  }) async {
    if (neededChunkIndices.isEmpty) {
      return;
    }

    final chunkUri = _buildChunkUri(hostUrl, purl, password);

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
    return result.neededChunks.isEmpty;
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
    int parallelism = 4,
    void Function(int bytesHashed, int totalBytes)? onHashProgress,
    void Function(int chunksDone, int chunksTotal)? onUploadProgress,
  }) async {
    // Step 1: hash
    final hashed = await hashFile(filePath, onProgress: onHashProgress);

    // Step 2: initial handshake — find out which chunks the server needs.
    // Even if need==[] (server has all chunks from a prior attempt), we MUST
    // still send the confirmation handshake (step 4) to trigger server-side
    // finalization.  Skipping it leaves the file as .PARTIAL indefinitely.
    final handshakeResult = await handshake(hashed, hostUrl, uploadPath, password);

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
    final confirmed = await handshake(hashed, hostUrl, uploadPath, password);
    if (confirmed.neededChunks.isNotEmpty) {
      throw CopypartyUploadException(
        'Upload confirmation failed: server still needs '
        '${confirmed.neededChunks.length} chunk(s)',
      );
    }
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
    final base = hostUrl.trimRight();
    final cleanPath = uploadPath.replaceAll(RegExp(r'^/+|/+$'), '');
    final uri = Uri.parse('$base/$cleanPath/').replace(
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
