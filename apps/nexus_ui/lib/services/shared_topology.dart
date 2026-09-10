import 'dart:ui';

/// One global coordinate system, independent of the viewing device.
/// Lamport revision + author gives every replica the same conflict winner.
class SharedTopology {
  SharedTopology(this.revision, this.author, Map<String, Offset> points)
    : points = Map.unmodifiable(points);
  final int revision;
  final String author;
  final Map<String, Offset> points;

  static SharedTopology? parse(dynamic value) {
    if (value is! Map || value['schema'] != 1) return null;
    final revision = value['revision'];
    final author = value['author'];
    final raw = value['points'];
    if (revision is! int ||
        revision < 1 ||
        revision > 9007199254740990 ||
        author is! String ||
        author.isEmpty ||
        author.length > 128 ||
        raw is! Map ||
        raw.isEmpty ||
        raw.length > 128) {
      return null;
    }
    final points = <String, Offset>{};
    for (final entry in raw.entries) {
      final id = entry.key;
      final xy = entry.value;
      if (id is! String ||
          id.isEmpty ||
          id.length > 128 ||
          id == 'self' ||
          xy is! List ||
          xy.length != 2 ||
          !xy.every((n) => n is num && n.isFinite && n.abs() <= 1000000)) {
        return null;
      }
      points[id] = Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
    }
    if (!points.containsKey(author)) return null;
    return SharedTopology(revision, author, points);
  }

  bool newerThan(SharedTopology? other) =>
      other == null ||
      revision > other.revision ||
      (revision == other.revision && author.compareTo(other.author) > 0);

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'revision': revision,
    'author': author,
    'points': points.map((id, p) => MapEntry(id, [p.dx, p.dy])),
  };

  Map<String, Offset> relativeTo(String id) {
    final origin = points[id];
    if (origin == null) return {};
    return {
      for (final e in points.entries)
        if (e.key != id) e.key: e.value - origin,
    };
  }

  SharedTopology move(String localId, String target, Offset relative) {
    final origin = points[localId];
    if (origin == null) throw StateError('Dispositivo assente dalla topologia');
    return SharedTopology(revision + 1, localId, {
      ...points,
      target: origin + relative,
    });
  }
}
