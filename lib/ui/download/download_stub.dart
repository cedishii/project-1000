import 'dart:typed_data';

/// Not available outside a browser (phones save or share files instead).
void downloadBytes(String name, Uint8List bytes, String mimeType) =>
    throw UnsupportedError('Downloads are only available in a browser');
