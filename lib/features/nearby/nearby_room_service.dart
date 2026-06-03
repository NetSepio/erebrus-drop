import '../../features/join/join_room_service.dart';

class NearbyRoomService {
  static const serviceType = '_erebrusdrop._tcp';

  Stream<List<JoinRoomPreview>> watchRooms() {
    // mDNS/DNS-SD plugin integration belongs here.
    return Stream<List<JoinRoomPreview>>.value(const <JoinRoomPreview>[]);
  }
}
