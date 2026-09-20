import 'package:flutter_test/flutter_test.dart';
import 'package:myemail/ui/folder_tree/folder_tile.dart';

/// The numbers after a folder's name.
void main() {
  test('unread, then everything', () {
    expect(formatFolderCounts(14, 2310), '14/2310');
    expect(formatFolderCounts(0, 41), '0/41', reason: 'a read folder still has a size');
  });

  test('nothing for an empty folder', () {
    expect(formatFolderCounts(0, 0), isNull);
  });

  test('big numbers are capped so the name keeps its room', () {
    expect(formatFolderCounts(1200, 15000), '999+/9999+');
  });
}
