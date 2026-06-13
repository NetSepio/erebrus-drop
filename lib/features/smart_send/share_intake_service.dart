import 'dart:async';

import 'package:flutter/services.dart';

class SharedPayload {
  const SharedPayload({this.text, this.filePaths = const <String>[]});

  final String? text;
  final List<String> filePaths;

  bool get isEmpty => (text == null || text!.isEmpty) && filePaths.isEmpty;

  factory SharedPayload.fromJson(Map<Object?, Object?> json) {
    return SharedPayload(
      text: json['text']?.toString(),
      filePaths:
          (json['filePaths'] as List?)
              ?.whereType<Object?>()
              .map((value) => value.toString())
              .where((value) => value.isNotEmpty)
              .toList() ??
          const <String>[],
    );
  }
}

class ShareIntakeService {
  static const MethodChannel _channel = MethodChannel(
    'com.erebrus.drop/network',
  );

  Future<SharedPayload?> consumeInitialShare() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'consumeSharedPayload',
      );
      if (result == null) return null;
      final payload = SharedPayload.fromJson(result);
      return payload.isEmpty ? null : payload;
    } on MissingPluginException {
      return null;
    }
  }

  Stream<SharedPayload> watchIncomingShares() {
    final controller = StreamController<SharedPayload>();
    Timer? timer;
    Future<void> poll() async {
      final payload = await consumeInitialShare();
      if (payload != null && !controller.isClosed) {
        controller.add(payload);
      }
    }

    timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(poll()),
    );
    unawaited(poll());
    controller.onCancel = () => timer?.cancel();
    return controller.stream;
  }
}
