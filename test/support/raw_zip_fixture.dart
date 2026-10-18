import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';

class RawZipFixtureBuilder {
  final BytesBuilder _out = BytesBuilder();
  final List<_RawZipEntry> _entries = <_RawZipEntry>[];

  static List<int> _u16(int v) => <int>[v & 0xff, (v >> 8) & 0xff];
  static List<int> _u32(int v) => <int>[
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ];

  void add(String name, List<int> data) {
    final List<int> nameBytes = utf8.encode(name);
    final int crc = getCrc32(data);
    final int offset = _out.length;
    _out.add(_u32(0x04034b50));
    _out.add(_u16(20));
    _out.add(_u16(0)); // flags
    _out.add(_u16(0)); // method: stored
    _out.add(_u16(0));
    _out.add(_u16(0)); // time/date
    _out.add(_u32(crc));
    _out.add(_u32(data.length));
    _out.add(_u32(data.length));
    _out.add(_u16(nameBytes.length));
    _out.add(_u16(0)); // extra length
    _out.add(nameBytes);
    _out.add(data);
    _entries.add(_RawZipEntry(name, crc, data.length, offset));
  }

  Uint8List build() {
    final int cdOffset = _out.length;
    for (final _RawZipEntry entry in _entries) {
      final List<int> nameBytes = utf8.encode(entry.name);
      _out.add(_u32(0x02014b50));
      _out.add(_u16(63));
      _out.add(_u16(20));
      _out.add(_u16(0)); // flags
      _out.add(_u16(0)); // method: stored
      _out.add(_u16(0));
      _out.add(_u16(0)); // time/date
      _out.add(_u32(entry.crc));
      _out.add(_u32(entry.size));
      _out.add(_u32(entry.size));
      _out.add(_u16(nameBytes.length));
      _out.add(_u16(0)); // extra
      _out.add(_u16(0)); // comment
      _out.add(_u16(0)); // disk
      _out.add(_u16(0)); // internal attrs
      _out.add(_u32(0)); // external attrs
      _out.add(_u32(entry.offset));
      _out.add(nameBytes);
    }
    final int cdSize = _out.length - cdOffset;
    _out.add(_u32(0x06054b50));
    _out.add(_u16(0));
    _out.add(_u16(0)); // disk numbers
    _out.add(_u16(_entries.length));
    _out.add(_u16(_entries.length));
    _out.add(_u32(cdSize));
    _out.add(_u32(cdOffset));
    _out.add(_u16(0)); // comment length
    return _out.takeBytes();
  }
}

class _RawZipEntry {
  _RawZipEntry(this.name, this.crc, this.size, this.offset);
  final String name;
  final int crc;
  final int size;
  final int offset;
}
