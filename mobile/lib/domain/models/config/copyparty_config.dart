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
          other.sortSmallestFirst == sortSmallestFirst);

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
  );

  @override
  String toString() =>
      'CopypartyConfig(hostUrl: $hostUrl, uploadPath: $uploadPath, '
      'parallelConnections: $parallelConnections, autoDeleteAfterVerify: $autoDeleteAfterVerify, '
      'writeReceipts: $writeReceipts, triggerExtensions: $triggerExtensions, '
      'allowSelfSignedCert: $allowSelfSignedCert, '
      'recreateFolderStructure: $recreateFolderStructure, '
      'sortSmallestFirst: $sortSmallestFirst)';

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
