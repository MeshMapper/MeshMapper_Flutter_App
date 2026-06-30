import 'dart:typed_data';

/// Minimal decoder for MeshMapper's coverage vector tiles (vector_tile.php) —
/// just enough of the MVT/protobuf wire format to extract each cell's
/// `{id, i, j, st}`. Geometry is skipped entirely: a cell's rectangle is
/// reconstructed from its grid indices (i, j) and the grid step table, which
/// is byte-identical to what the server encoded (both compute corners from
/// indices). Contract reference: MeshMapper_Server/docs/VECTOR_TILES.md.
///
/// WEB-SAFE BY DESIGN: feature ids run up to ~2^42 and dart2js truncates
/// bitwise ops to 32 bits, so varint/zigzag decoding here uses arithmetic
/// (`*`, `~/`, `%`) only — same rule as WireTagCodec.

/// gsize (metres) -> [latStep, lonStep] degrees. KEEP IN SYNC with
/// `coverageGridPresets()` in MeshMapper_Server dev/coverage_cells.php
/// (the app only ever uses the 300/100 presets).
const Map<int, List<double>> kCoverageGridSteps = {
  300: [0.0027, 0.00384],
  100: [0.0009, 0.00128],
};

/// One coverage cell from a decoded tile. `st` is the server's status
/// category (1=green 2=cyan 3=orange 4=purple 5=grey 6=red).
class CoverageCell {
  final int id;
  final int i;
  final int j;
  final int st;
  const CoverageCell(this.id, this.i, this.j, this.st);
}

class _Reader {
  final Uint8List buf;
  int pos = 0;
  _Reader(this.buf);

  bool get done => pos >= buf.length;

  /// Varint as a Dart int via arithmetic (exact up to 2^53 — ids are < 2^53).
  int varint() {
    var value = 0;
    var multiplier = 1;
    while (true) {
      final b = buf[pos++];
      value += (b % 128) * multiplier;
      if (b < 128) return value;
      multiplier *= 128;
    }
  }

  Uint8List bytes(int len) {
    final out = Uint8List.sublistView(buf, pos, pos + len);
    pos += len;
    return out;
  }
}

int _unzigzag(int n) => n.isOdd ? -((n + 1) ~/ 2) : n ~/ 2;

/// Decodes the cells of a single-layer coverage MVT (uncompressed bytes —
/// package:http has already gunzipped the response). Returns const [] for
/// anything that doesn't parse as expected: a tile we can't read must never
/// break the wardriving flow, the patch just skips it.
List<CoverageCell> decodeCoverageCells(Uint8List mvt) {
  try {
    final tile = _Reader(mvt);
    while (!tile.done) {
      final tag = tile.varint();
      final field = tag ~/ 8;
      final wire = tag % 8;
      if (field == 3 && wire == 2) {
        return _decodeLayer(_Reader(tile.bytes(tile.varint())));
      }
      _skip(tile, wire);
    }
  } catch (_) {
    // Malformed/foreign tile — treated as empty below.
  }
  return const [];
}

List<CoverageCell> _decodeLayer(_Reader layer) {
  final keys = <String>[];
  final values = <int>[];
  final features = <_Reader>[];
  while (!layer.done) {
    final tag = layer.varint();
    final field = tag ~/ 8;
    final wire = tag % 8;
    if (field == 2 && wire == 2) {
      features.add(_Reader(layer.bytes(layer.varint())));
    } else if (field == 3 && wire == 2) {
      keys.add(String.fromCharCodes(layer.bytes(layer.varint())));
    } else if (field == 4 && wire == 2) {
      values.add(_decodeValue(_Reader(layer.bytes(layer.varint()))));
    } else {
      _skip(layer, wire);
    }
  }

  final cells = <CoverageCell>[];
  for (final f in features) {
    var id = 0;
    final tags = <int>[];
    while (!f.done) {
      final tag = f.varint();
      final field = tag ~/ 8;
      final wire = tag % 8;
      if (field == 1 && wire == 0) {
        id = f.varint();
      } else if (field == 2 && wire == 2) {
        final packed = _Reader(f.bytes(f.varint()));
        while (!packed.done) {
          tags.add(packed.varint());
        }
      } else {
        _skip(f, wire);
      }
    }
    int? i, j, st;
    for (var t = 0; t + 1 < tags.length; t += 2) {
      final key = tags[t] < keys.length ? keys[tags[t]] : '';
      final value = tags[t + 1] < values.length ? values[tags[t + 1]] : 0;
      if (key == 'i') i = value;
      if (key == 'j') j = value;
      if (key == 'st') st = value;
    }
    if (i != null && j != null && st != null) {
      cells.add(CoverageCell(id, i, j, st));
    }
  }
  return cells;
}

/// Value message: the server encodes all properties as sint64 (field 6).
int _decodeValue(_Reader value) {
  while (!value.done) {
    final tag = value.varint();
    final field = tag ~/ 8;
    final wire = tag % 8;
    if (field == 6 && wire == 0) return _unzigzag(value.varint());
    _skip(value, wire);
  }
  return 0;
}

void _skip(_Reader r, int wire) {
  if (wire == 0) {
    r.varint();
  } else if (wire == 2) {
    r.bytes(r.varint());
  } else if (wire == 5) {
    r.pos += 4;
  } else if (wire == 1) {
    r.pos += 8;
  } else {
    throw const FormatException('unsupported wire type');
  }
}
