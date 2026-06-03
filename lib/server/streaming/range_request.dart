class ByteRange {
  const ByteRange({required this.start, required this.endInclusive});

  final int start;
  final int endInclusive;

  int get length => endInclusive - start + 1;
}

ByteRange? parseRangeHeader(String? header, int totalBytes) {
  if (header == null || !header.startsWith('bytes=') || totalBytes <= 0) {
    return null;
  }
  final parts = header.substring(6).split('-');
  final start = int.tryParse(parts.first);
  final end = parts.length > 1 && parts[1].isNotEmpty
      ? int.tryParse(parts[1])
      : totalBytes - 1;
  if (start == null || end == null || start < 0 || end < start) {
    return null;
  }
  return ByteRange(
    start: start,
    endInclusive: end >= totalBytes ? totalBytes - 1 : end,
  );
}
