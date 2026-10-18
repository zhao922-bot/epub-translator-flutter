// The plain Dart entry delegates Flutter-dependent EPUB work to a Flutter VM.
import 'src/epub_maintenance_launcher.dart'
    if (dart.library.ui) 'src/repair_epub_xhtml_command.dart'
    as command;

Future<void> main(List<String> arguments) => command.repair(arguments);
