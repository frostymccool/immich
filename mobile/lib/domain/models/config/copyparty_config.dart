class CopypartyConfig {
  final String hostUrl;
  final String uploadPath;
  final int parallelConnections;
  final bool autoDeleteAfterVerify;
  final bool writeReceipts;
  final List<String> triggerExtensions;
  final bool allowSelfSignedCert;

  const CopypartyConfig({
    this.hostUrl = '',
    this.uploadPath = '/uploads',
    this.parallelConnections = 4,
    this.autoDeleteAfterVerify = false,
    this.writeReceipts = true,
    this.triggerExtensions = const ['lrv', 'insv', 'insp'],
    this.allowSelfSignedCert = false,
  });

  CopypartyConfig copyWith({
    String? hostUrl,
    String? uploadPath,
    int? parallelConnections,
    bool? autoDeleteAfterVerify,
    bool? writeReceipts,
    List<String>? triggerExtensions,
    bool? allowSelfSignedCert,
  }) => CopypartyConfig(
    hostUrl: hostUrl ?? this.hostUrl,
    uploadPath: uploadPath ?? this.uploadPath,
    parallelConnections: parallelConnections ?? this.parallelConnections,
    autoDeleteAfterVerify: autoDeleteAfterVerify ?? this.autoDeleteAfterVerify,
    writeReceipts: writeReceipts ?? this.writeReceipts,
    triggerExtensions: triggerExtensions ?? this.triggerExtensions,
    allowSelfSignedCert: allowSelfSignedCert ?? this.allowSelfSignedCert,
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
          other.allowSelfSignedCert == allowSelfSignedCert);

  @override
  int get hashCode => Object.hash(
    hostUrl,
    uploadPath,
    parallelConnections,
    autoDeleteAfterVerify,
    writeReceipts,
    Object.hashAll(triggerExtensions),
    allowSelfSignedCert,
  );

  @override
  String toString() =>
      'CopypartyConfig(hostUrl: $hostUrl, uploadPath: $uploadPath, '
      'parallelConnections: $parallelConnections, autoDeleteAfterVerify: $autoDeleteAfterVerify, '
      'writeReceipts: $writeReceipts, triggerExtensions: $triggerExtensions, '
      'allowSelfSignedCert: $allowSelfSignedCert)';

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
