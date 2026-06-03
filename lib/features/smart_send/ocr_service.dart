class OcrResult {
  const OcrResult({required this.text, required this.confidence});

  final String text;
  final double confidence;
}

class OcrService {
  Future<OcrResult> recognizeImageText(String imagePath) {
    throw UnsupportedError(
      'Offline OCR requires the native ML Kit/Vision channel.',
    );
  }
}
