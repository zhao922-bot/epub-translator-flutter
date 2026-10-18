// The plain Dart entry delegates Flutter-dependent EPUB work to a Flutter VM.
import 'src/epub_maintenance_launcher.dart'
    if (dart.library.ui) 'src/rebuild_translated_epub_command.dart'
    as command;

Future<void> main(List<String> arguments) => command.rebuild(arguments);
