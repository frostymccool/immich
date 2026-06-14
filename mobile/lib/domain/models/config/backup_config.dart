class BackupConfig {
  final bool enabled;
  final bool useCellularForVideos;
  final bool useCellularForPhotos;
  final bool requireCharging;
  final int triggerDelay;
  final bool syncAlbums;
  final int parallelUploads;
  final bool sortSmallestFirst;

  const BackupConfig({
    this.enabled = false,
    this.useCellularForVideos = false,
    this.useCellularForPhotos = false,
    this.requireCharging = false,
    this.triggerDelay = 30,
    this.syncAlbums = false,
    this.parallelUploads = 3,
    this.sortSmallestFirst = true,
  });

  BackupConfig copyWith({
    bool? enabled,
    bool? useCellularForVideos,
    bool? useCellularForPhotos,
    bool? requireCharging,
    int? triggerDelay,
    bool? syncAlbums,
    int? parallelUploads,
    bool? sortSmallestFirst,
  }) => BackupConfig(
    enabled: enabled ?? this.enabled,
    useCellularForVideos: useCellularForVideos ?? this.useCellularForVideos,
    useCellularForPhotos: useCellularForPhotos ?? this.useCellularForPhotos,
    requireCharging: requireCharging ?? this.requireCharging,
    triggerDelay: triggerDelay ?? this.triggerDelay,
    syncAlbums: syncAlbums ?? this.syncAlbums,
    parallelUploads: parallelUploads ?? this.parallelUploads,
    sortSmallestFirst: sortSmallestFirst ?? this.sortSmallestFirst,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BackupConfig &&
          other.enabled == enabled &&
          other.useCellularForVideos == useCellularForVideos &&
          other.useCellularForPhotos == useCellularForPhotos &&
          other.requireCharging == requireCharging &&
          other.triggerDelay == triggerDelay &&
          other.syncAlbums == syncAlbums &&
          other.parallelUploads == parallelUploads &&
          other.sortSmallestFirst == sortSmallestFirst);

  @override
  int get hashCode =>
      Object.hash(enabled, useCellularForVideos, useCellularForPhotos, requireCharging, triggerDelay, syncAlbums, parallelUploads, sortSmallestFirst);

  @override
  String toString() =>
      'BackupConfig(enabled: $enabled, useCellularForVideos: $useCellularForVideos, useCellularForPhotos: $useCellularForPhotos, requireCharging: $requireCharging, triggerDelay: $triggerDelay, syncAlbums: $syncAlbums, parallelUploads: $parallelUploads, sortSmallestFirst: $sortSmallestFirst)';
}
