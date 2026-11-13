/// A minimal CSV reader (RFC 4180: quoted fields, "" escapes, newlines
/// inside quotes). Returns one map per row, keyed by the trimmed header.
/// Missing cells become empty strings, like pandas' `fillna("")`.
List<Map<String, String>> parseCsv(String text) {
  if (text.startsWith('﻿')) text = text.substring(1);
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      row.add(field.toString());
      field.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  if (rows.isEmpty) return [];

  final header = rows.first.map((h) => h.trim()).toList();
  return [
    for (final cells in rows.skip(1))
      if (!(cells.length == 1 && cells.first.trim().isEmpty))
        {
          for (var c = 0; c < header.length; c++)
            header[c]: c < cells.length ? cells[c] : '',
        },
  ];
}
