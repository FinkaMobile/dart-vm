import 'dart:async';

class Room {
  Room(this.name);
  final String name;
  static Room create() => Room('preview');
}

class Inbox {
  final rooms = <Room>[Room('original')];
  int refreshes = 0;
  Future<int> closeRoom(Room room) async {
    refreshes++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    rooms.add(room);
    return rooms.length;
  }
}

final inbox = Inbox();
void main() {
  print(inbox.rooms.single.name);
  Timer.periodic(const Duration(minutes: 1), (_) {});
}
