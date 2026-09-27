import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // No minimum window size is enforced on Windows: this project has no
  // window_manager/window_size dependency, and there is no window-sizing
  // platform channel. The layout is responsive (scrollable sections, wrapping
  // controls), so extremely narrow windows degrade gracefully instead of
  // clipping. If a hard minimum is ever wanted, handle WM_GETMINMAXINFO in
  // windows/runner/win32_window.cpp rather than adding a dependency.
  runApp(const ProviderScope(child: EpubTranslatorApp()));
}
