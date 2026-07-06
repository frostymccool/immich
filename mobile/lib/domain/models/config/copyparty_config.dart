class CopypartyConfig {
  final String hostUrl;
  final String uploadPath;
  final int parallelConnections;
  final bool autoDeleteAfterVerify;
  final bool writeReceipts;
  final List<String> triggerExtensions;
  final bool allowSelfSignedCert;

  /// When true, imports recreate the picked folder's structure beneath the
  /// upload path (the picked folder's name becomes a subfolder). Moved from a
  /// per-import checkbox to a persistent setting. (Q3)
  final bool recreateFolderStructure;

  /// When true, upload groups smallest-first (by the group's total byte size)
  /// so quick wins land first on slow links. (item 4)
  final bool sortSmallestFirst;

  /// When true, self-test/diagnostic actions are shown across the copyparty
  /// pages. Default off — normal use keeps those hidden. (item 5)
  final bool debugMode;

  /// When true, each file is first COPIED from the (slow/removable) source
  /// volume to local phone storage, then hashed + uploaded from that local
  /// copy. This cuts USB read time, lets an upload finish even if the card is
  /// pulled mid-transfer, and makes an interrupted upload resumable without
  /// re-reading the source. Falls back to reading directly from the source when
  /// phone storage is too low. Default ON. (batch: item 4)
  final bool stageToLocalBeforeUpload;

  const CopypartyConfig({
    this.hostUrl = '',
    this.uploadPath = '/uploads',
    this.parallelConnections = 4,
    this.autoDeleteAfterVerify = false,
    this.writeReceipts = true,
    this.triggerExtensions = const ['lrv', 'insv', 'insp'],
    this.allowSelfSignedCert = false,
    this.recreateFolderStructure = false,
    this.sortSmallestFirst = false,
    this.debugMode = false,
    this.stageToLocalBeforeUpload = true,
  });

  CopypartyConfig copyWith({
    String? hostUrl,
    String? uploadPath,
    int? parallelConnections,
    bool? autoDeleteAfterVerify,
    bool? writeReceipts,
    List<String>? triggerExtensions,
    bool? allowSelfSignedCert,
    bool? recreateFolderStructure,
    bool? sortSmallestFirst,
    bool? debugMode,
    bool? stageToLocalBeforeUpload,
  }) => CopypartyConfig(
    hostUrl: hostUrl ?? this.hostUrl,
    uploadPath: uploadPath ?? this.uploadPath,
    parallelConnections: parallelConnections ?? this.parallelConnections,
    autoDeleteAfterVerify: autoDeleteAfterVerify ?? this.autoDeleteAfterVerify,
    writeReceipts: writeReceipts ?? this.writeReceipts,
    triggerExtensions: triggerExtensions ?? this.triggerExtensions,
    allowSelfSignedCert: allowSelfSignedCert ?? this.allowSelfSignedCert,
    recreateFolderStructure: recreateFolderStructure ?? this.recreateFolderStructure,
    sortSmallestFirst: sortSmallestFirst ?? this.sortSmallestFirst,
    debugMode: debugMode ?? this.debugMode,
    stageToLocalBeforeUpload: stageToLocalBeforeUpload ?? this.stageToLocalBeforeUpload,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CopypartyConfig &&
          other.hostUrl == hostUrl &&
          other.uploadPath == uploadPath &&
          other.parallelConnections == parallelConnections &&
          other.autoDeleteAfterVerify == autoDeleteAfterVerify &&
          other.writeReceipts == writeReceipts &&
          _listEquals(other.triggerExtensions, triggerExtensions) &&
          other.allowSelfSignedCert == allowSelfSignedCert &&
          other.recreateFolderStructure == recreateFolderStructure &&
          other.sortSmallestFirst == sortSmallestFirst &&
          other.debugMode == debugMode &&
          other.stageToLocalBeforeUpload == stageToLocalBeforeUpload);

  @override
  int get hashCode => Object.hash(
    hostUrl,
    uploadPath,
    parallelConnections,
    autoDeleteAfterVerify,
    writeReceipts,
    Object.hashAll(triggerExtensions),
    allowSelfSignedCert,
    recreateFolderStructure,
    sortSmallestFirst,
    debugMode,
    stageToLocalBeforeUpload,
  );

  @override
  String toString() =>
      'CopypartyConfig(hostUrl: $hostUrl, uploadPath: $uploadPath, '
      'parallelConnections: $parallelConnections, autoDeleteAfterVerify: $autoDeleteAfterVerify, '
      'writeReceipts: $writeReceipts, triggerExtensions: $triggerExtensions, '
      'allowSelfSignedCert: $allowSelfSignedCert, '
      'recreateFolderStructure: $recreateFolderStructure, '
      'sortSmallestFirst: $sortSmallestFirst, debugMode: $debugMode, '
      'stageToLocalBeforeUpload: $stageToLocalBeforeUpload)';

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
