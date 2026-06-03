class SharedPayload {
  const SharedPayload({this.text, this.filePaths = const <String>[]});

  final String? text;
  final List<String> filePaths;

  bool get isEmpty => (text == null || text!.isEmpty) && filePaths.isEmpty;
}

class ShareIntakeService {
  Stream<SharedPayload> watchIncomingShares() {
    // receive_sharing_intent integration belongs here.
    return Stream<SharedPayload>.empty();
  }
}
