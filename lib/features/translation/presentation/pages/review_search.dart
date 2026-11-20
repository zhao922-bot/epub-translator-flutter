import 'dart:async';

/// Delays filtering while the user is typing.
class ReviewSearch {
  Timer? _timer;
  String _query = '';

  String get query => _query;

  void update(String input, void Function() filter) {
    _timer?.cancel();
    final next = input.trim().toLowerCase();
    if (next == _query) return;
    _timer = Timer(const Duration(milliseconds: 250), () {
      _query = next;
      filter();
    });
  }

  void reset() {
    _timer?.cancel();
    _query = '';
  }

  void dispose() => _timer?.cancel();
}
