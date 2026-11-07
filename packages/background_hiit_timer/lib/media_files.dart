import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// References are relative to this installation's private media directory.
abstract final class MediaFiles {
  static bool isLocal(String value) => value.startsWith('local:');

  static String relativePath(String reference) {
    if (!isLocal(reference)) {
      throw const FormatException('Not a local media reference.');
    }
    final relative = reference.substring(6);
    final parts = relative.split('/');
    if (parts.length != 2 ||
        !{'audio', 'images'}.contains(parts[0]) ||
        !RegExp(r'^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$').hasMatch(parts[1]) ||
        parts[1] == '.' ||
        parts[1] == '..') {
      throw const FormatException('Invalid local media reference.');
    }
    return relative;
  }

  static Future<Directory> root() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'media'));

  static Future<File> file(String reference, {Directory? directory}) async {
    final relative = relativePath(reference);
    final rootDirectory = directory ?? await root();
    final folder =
        Directory(p.join(rootDirectory.path, relative.split('/').first));
    for (final path in [rootDirectory.path, folder.path]) {
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FileSystemException(
            'Media directories cannot be symbolic links.');
      }
    }
    final result = File(p.join(rootDirectory.path, relative));
    if (await FileSystemEntity.type(result.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('Media files cannot be symbolic links.');
    }
    return result;
  }

  static String displayName(String reference) {
    final name = p.posix.basename(reference);
    return name.length > 37 && name[36] == '_' ? name.substring(37) : name;
  }

  static String failureKey(String reference) => 'mediaFailure:$reference';
}
