import '../../core/drop_models.dart';
import '../../server/drop_server.dart';

class LibraryRepository {
  const LibraryRepository(this._server);

  final DropServer _server;

  Future<List<DropFileItem>> rootItems() {
    if (!_server.isRunning) {
      return Future<List<DropFileItem>>.value(const <DropFileItem>[]);
    }
    return _server.listFiles('/');
  }

  Future<StorageSnapshot> storage() {
    return _server.storageSnapshot();
  }
}
