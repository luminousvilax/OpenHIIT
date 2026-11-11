import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Channel fixture for exercising the real browser route and import pipeline.
void mockBrowserSelection(
    {required bool audio, required Future<String?> Function() select}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('openhiit/media_picker'),
          (call) async {
    switch (call.method) {
      case 'initialize':
      case 'state':
        return {
          'permission': 'full',
          'folders': [],
          'file': null,
          'name': null,
          'location': {
            'source': 'library',
            'directory': 'external_primary/Fixtures/'
          },
          'sort': 'name',
          'ascending': true,
          'grid': !audio,
          'showNames': true,
          'largePreviews': false,
        };
      case 'list':
        return [
          {
            'id': 'content://fixtures/file',
            'name': audio ? '声音.mp3' : '背景.png',
            'folder': false
          }
        ];
      case 'select':
        expect((call.arguments as Map)['audio'], audio);
        return select();
      case 'thumbnail':
      case 'cancelThumbnails':
      case 'saveView':
        return null;
      default:
        throw StateError('Unexpected method ${call.method}');
    }
  });
}

void clearBrowserChannel() =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('openhiit/media_picker'), null);
