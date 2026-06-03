import 'dart:io' show Directory, Platform;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'native_platform_bridge.dart';

class PlatformUtils {
  const PlatformUtils._();

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isWindows => !kIsWeb && Platform.isWindows;

  static bool get supportsDirectoryPicker => !isAndroid;

  static Future<String?> pickEpubFile() {
    return NativePlatformBridge.pickEpubFile();
  }

  static Future<String?> pickDirectory() {
    return NativePlatformBridge.pickDirectory();
  }

  static Future<String?> saveToDownloads({
    required String sourcePath,
    required String displayName,
  }) {
    return NativePlatformBridge.saveToDownloads(
      sourcePath: sourcePath,
      displayName: displayName,
    );
  }

  static Future<void> shareFile({
    required String sourcePath,
    required String displayName,
  }) {
    return NativePlatformBridge.shareFile(
      sourcePath: sourcePath,
      displayName: displayName,
    );
  }

  static Future<String> appDocumentsDirectory() async {
    final String? directory =
        await NativePlatformBridge.appDocumentsDirectory();
    if (directory != null && directory.isNotEmpty) {
      await Directory(directory).create(recursive: true);
      return directory;
    }

    final Directory fallback = Directory.current;
    return fallback.path;
  }

  static Future<String> defaultOutputDirectory([String? inputPath]) async {
    if (isAndroid) {
      final Directory directory = Directory(await appDocumentsDirectory());
      final Directory outputDirectory = Directory(
        path.join(directory.path, 'translated_epubs'),
      );
      await outputDirectory.create(recursive: true);
      return outputDirectory.path;
    }

    if (inputPath != null && inputPath.isNotEmpty) {
      return path.dirname(inputPath);
    }

    return appDocumentsDirectory();
  }
}
